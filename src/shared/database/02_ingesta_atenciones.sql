/* =============================================================================
   02 · Migración para cargar atenciones_2026.xlsx sobre schema_core_fixed.sql
   Ejecutar UNA vez, después del esquema base (no es idempotente: usa ALTER).
   ============================================================================= */
USE ctrl_core_db;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

/* 1. La hoja trae contactos sin documento (solo "Luis", "Sara Gómez"):
      personas exigía tipo_documento_id y numero_documento NOT NULL.
      El UNIQUE (tenant, tipo, numero) sigue valiendo: MySQL permite varios NULL. */
ALTER TABLE personas
  MODIFY tipo_documento_id SMALLINT UNSIGNED NULL,
  MODIFY numero_documento  VARCHAR(25) NULL;

/* 2. Dos listas cerradas nuevas: formalización y brecha del diagnóstico */
ALTER TABLE catalogo_items
  MODIFY tipo ENUM('sector','tamano','vinculo_unab','tipo_documento','eje_diagnostico',
                   'area_asesoria','tipo_evento','nivel','medalla',
                   'formalizacion','brecha') NOT NULL;

INSERT INTO catalogo_items (tenant_id, tipo, codigo, nombre, orden) VALUES
 (NULL,'sector','agroindustria','Agroindustria',13),
 (NULL,'formalizacion','ninguna','Ninguna',1),
 (NULL,'formalizacion','rut','RUT',2),
 (NULL,'formalizacion','rut_camara','RUT + Cámara de Comercio',3),
 (NULL,'brecha','inventario','Inventario',1),
 (NULL,'brecha','marketing_digital','Marketing Digital',2),
 (NULL,'brecha','mercadeo','Mercadeo',3),
 (NULL,'brecha','calidad','Calidad',4),
 (NULL,'brecha','finanzas','Finanzas',5),
 (NULL,'brecha','costos','Costos',6),
 (NULL,'brecha','operaciones','Operaciones',7),
 (NULL,'brecha','ventas','Ventas',8),
 (NULL,'brecha','formalizacion','Formalización',9);

/* 3. Formalización a nivel empresa (el valor más completo reportado en sus atenciones) */
ALTER TABLE empresas
  ADD COLUMN formalizacion_id SMALLINT UNSIGNED NULL AFTER tamano_id,
  ADD KEY idx_empresas_formalizacion (formalizacion_id),
  ADD CONSTRAINT fk_empresas_formalizacion FOREIGN KEY (formalizacion_id) REFERENCES catalogo_items (id);

/* 4. Trazabilidad del archivo cargado */
ALTER TABLE migracion_lotes
  ADD COLUMN archivo_nombre VARCHAR(190) NULL AFTER usuario_id,
  ADD COLUMN filas_leidas   INT UNSIGNED NOT NULL DEFAULT 0 AFTER total_empresas_unicas;

/* 5. Una fila por atención de la hoja (hasta hoy el esquema solo guardaba contadores) */
CREATE TABLE atenciones (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id          INT UNSIGNED NOT NULL,
  lote_id            BIGINT UNSIGNED NOT NULL,
  codigo_externo     VARCHAR(30)  NOT NULL COMMENT 'ID_Atencion de la hoja (AT-001)',
  empresa_id         BIGINT UNSIGNED NOT NULL COMMENT 'Empresa canónica tras la deduplicación por NIT',
  persona_id         BIGINT UNSIGNED NULL,
  empresa_nombre_origen VARCHAR(200) NOT NULL COMMENT 'Texto tal como vino en la hoja',
  nit_origen         VARCHAR(30)  NOT NULL COMMENT 'NIT tal como vino en la hoja',
  sector_id          SMALLINT UNSIGNED NULL,
  tamano_id          SMALLINT UNSIGNED NULL,
  formalizacion_id   SMALLINT UNSIGNED NULL,
  vinculo_unab_id    SMALLINT UNSIGNED NULL,
  brecha_id          SMALLINT UNSIGNED NULL,
  periodo            CHAR(6) NOT NULL COMMENT 'Mismo formato que fn_periodo (2026-2)',
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_atenciones_codigo (tenant_id, codigo_externo),
  KEY idx_atenciones_empresa (tenant_id, empresa_id),
  KEY idx_atenciones_periodo (tenant_id, periodo),
  KEY idx_atenciones_lote    (tenant_id, lote_id),
  KEY idx_atenciones_brecha  (brecha_id),
  CONSTRAINT fk_atenciones_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_atenciones_lote    FOREIGN KEY (tenant_id, lote_id)    REFERENCES migracion_lotes (tenant_id, id),
  CONSTRAINT fk_atenciones_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_atenciones_persona FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT fk_atenciones_sector  FOREIGN KEY (sector_id)        REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_tamano  FOREIGN KEY (tamano_id)        REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_formal  FOREIGN KEY (formalizacion_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_vinculo FOREIGN KEY (vinculo_unab_id)  REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_brecha  FOREIGN KEY (brecha_id)        REFERENCES catalogo_items (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Atenciones cargadas desde la hoja de cálculo';

/* 6. El dashboard por sector ahora cuenta también las atenciones cargadas */
CREATE OR REPLACE VIEW vw_dashboard_sector AS
SELECT a.tenant_id, a.periodo, s.id AS sector_id, COALESCE(s.nombre, 'Sin sector') AS sector,
       COUNT(DISTINCT a.empresa_id) AS empresas_atendidas,
       COUNT(*) AS atenciones,
       ROUND(100 * COUNT(DISTINCT a.empresa_id)
             / SUM(COUNT(DISTINCT a.empresa_id)) OVER (PARTITION BY a.tenant_id, a.periodo), 1) AS pct_empresas
FROM (
  SELECT c.tenant_id, c.empresa_id, fn_periodo(c.inicio_at) AS periodo
    FROM citas_asesoria c WHERE c.estado <> 'cancelada'
  UNION ALL
  SELECT p.tenant_id, p.empresa_id, fn_periodo(p.fecha_inicio) FROM proyectos_aula p
  UNION ALL
  SELECT i.tenant_id, i.empresa_id, fn_periodo(i.checkin_at)
    FROM evento_inscripciones i WHERE i.checkin_at IS NOT NULL
  UNION ALL
  SELECT t.tenant_id, t.empresa_id, t.periodo FROM atenciones t
) a
JOIN empresas e ON e.tenant_id = a.tenant_id AND e.id = a.empresa_id AND e.deleted_at IS NULL
LEFT JOIN catalogo_items s ON s.id = e.sector_id
GROUP BY a.tenant_id, a.periodo, s.id, COALESCE(s.nombre, 'Sin sector');
