/* =============================================================================
   CDE UNAB · Plataforma multitenant (B2B SaaS) - VERSIÓN CORREGIDA Y ESTABLE
   Motor      : MySQL 8.0+ / Compatible con entorno de producción y pruebas ETL
   Esquema    : 26 tablas, 3FN, aislamiento por tenant_id
   ============================================================================= */

DROP DATABASE IF EXISTS ctrl_core_db;
CREATE DATABASE ctrl_core_db
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_unicode_ci;

USE ctrl_core_db;

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET time_zone = '-05:00';
SET FOREIGN_KEY_CHECKS = 0;

/* Limpieza idempotente completa (Vistas, Triggers, Funciones y Tablas) */
DROP VIEW IF EXISTS vw_planes_accion_estado, vw_dashboard_sector, vw_evento_embudo,
  vw_empresa_gamificacion, vw_expediente_360, vw_empresa_resumen;

DROP TRIGGER IF EXISTS trg_empresas_bu_vector;
DROP TRIGGER IF EXISTS trg_empresas_bi_validacion;
DROP TRIGGER IF EXISTS trg_empresas_bu_validacion;
DROP TRIGGER IF EXISTS trg_usuarios_bi_validacion;
DROP TRIGGER IF EXISTS trg_usuarios_bu_validacion;
DROP TRIGGER IF EXISTS trg_dup_bi_orden;
DROP TRIGGER IF EXISTS trg_xp_bu_inmutable;
DROP TRIGGER IF EXISTS trg_xp_bd_inmutable;
DROP TRIGGER IF EXISTS trg_audit_bu_inmutable;
DROP TRIGGER IF EXISTS trg_audit_bd_inmutable;

DROP FUNCTION IF EXISTS fn_periodo;

DROP TABLE IF EXISTS sdui_esquemas, ia_consultas, duplicados_candidatos, migracion_lotes,
  reglas_automatizacion, empresa_medallas, xp_movimientos, empresa_misiones,
  planes_accion, autodiagnostico_respuestas, autodiagnosticos, evento_inscripciones,
  evento_convocatorias, eventos, citas_asesoria, misiones, proyecto_estudiantes,
  proyectos_aula, empresa_alias, personas, auditoria_seguridad, refresh_tokens,
  usuarios, empresas, catalogo_items, tenants;

/* ---------------------------------------------------------------------------
   1. PLATAFORMA Y SEGURIDAD
   --------------------------------------------------------------------------- */

CREATE TABLE tenants (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Cliente B2B (universidad, cámara de comercio)',
  slug        VARCHAR(60)  NOT NULL COMMENT 'Identificador legible/subdominio (ej. unab-cde)',
  nombre      VARCHAR(150) NOT NULL COMMENT 'Nombre de la institución',
  plan        ENUM('starter','pro','enterprise') NOT NULL DEFAULT 'starter',
  activo      TINYINT(1)   NOT NULL DEFAULT 1,
  created_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_tenants_slug (slug)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Clientes B2B de la plataforma (multitenant)';

/* ---------------------------------------------------------------------------
   2. CATÁLOGO UNIFICADO
   --------------------------------------------------------------------------- */
CREATE TABLE catalogo_items (
  id          SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NULL COMMENT 'NULL = valor global de la plataforma',
  tenant_key  INT UNSIGNED GENERATED ALWAYS AS (IFNULL(tenant_id, 0)) VIRTUAL COMMENT 'Auxiliar para UNIQUE con NULL',
  tipo        ENUM('sector','tamano','vinculo_unab','tipo_documento','eje_diagnostico','area_asesoria','tipo_evento','nivel','medalla','formalizacion','brecha') NOT NULL,
  codigo      VARCHAR(40)  NOT NULL,
  nombre      VARCHAR(100) NOT NULL,
  valor       INT NULL COMMENT 'XP requerido en tipo=nivel',
  orden       SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  activo      TINYINT(1) NOT NULL DEFAULT 1,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_catalogo_tenant_tipo_codigo (tenant_key, tipo, codigo),
  KEY idx_catalogo_tipo_activo_orden (tipo, activo, orden),
  CONSTRAINT fk_catalogo_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Catálogo unificado de listas cerradas';

/* ---------------------------------------------------------------------------
   3. ENTIDADES MAESTRAS (empresas, usuarios, personas, alias)
   --------------------------------------------------------------------------- */
CREATE TABLE empresas (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id         INT UNSIGNED NOT NULL,
  nit               VARCHAR(20)  NULL COMMENT 'NIT limpio; permite coexistir en estado por_revisar antes de fusionar',
  nit_activo_key    VARCHAR(20)  GENERATED ALWAYS AS (IF(estado = 'activa' AND deleted_at IS NULL, nit, NULL)) VIRTUAL
                    COMMENT 'Garantiza NIT único solo entre empresas canónicas activas (MDM)',
  razon_social      VARCHAR(200) NOT NULL,
  nombre_comercial  VARCHAR(200) NOT NULL,
  sector_id         SMALLINT UNSIGNED NULL COMMENT 'NULL permitido para soportar el 64% de empresas sin sector en ingesta',
  tamano_id         SMALLINT UNSIGNED NULL COMMENT 'FK catalogo_items (tipo=tamano)',
  formalizacion_id  SMALLINT UNSIGNED NULL,
  municipio         VARCHAR(80)  NULL,
  email_contacto    VARCHAR(190) NULL,
  telefono          VARCHAR(25)  NULL,
  numero_empleados  SMALLINT UNSIGNED NULL,
  estado            ENUM('activa','inactiva','por_revisar','fusionada') NOT NULL DEFAULT 'activa',
  fusionada_en_id   BIGINT UNSIGNED NULL COMMENT 'Empresa sobreviviente si estado=fusionada',
  fuente_origen     VARCHAR(60)  NULL,
  vector_sync       ENUM('pendiente','sincronizado','error') NOT NULL DEFAULT 'pendiente',
  vector_hash       CHAR(64)     NULL,
  deleted_at        DATETIME(3)  NULL,
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_empresas_tenant_id  (tenant_id, id),
  UNIQUE KEY uq_empresas_tenant_nit_activo (tenant_id, nit_activo_key),
  KEY idx_empresas_nit_raw       (tenant_id, nit),
  KEY idx_empresas_sector_estado (tenant_id, sector_id, estado, deleted_at),
  KEY idx_empresas_estado        (tenant_id, estado, deleted_at),
  KEY idx_empresas_vector_sync   (tenant_id, vector_sync),
  KEY idx_empresas_fusionada_en  (tenant_id, fusionada_en_id),
  KEY idx_empresas_tamano        (tamano_id),
  FULLTEXT KEY ft_empresas_nombre (razon_social, nombre_comercial),
  CONSTRAINT fk_empresas_tenant    FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_empresas_sector    FOREIGN KEY (sector_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_empresas_tamano    FOREIGN KEY (tamano_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_empresas_formalizacion FOREIGN KEY (formalizacion_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_empresas_fusionada FOREIGN KEY (tenant_id, fusionada_en_id) REFERENCES empresas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Empresas únicas atendidas (maestra del Expediente 360)';

CREATE TABLE usuarios (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  email           VARCHAR(190) NOT NULL,
  password_hash   VARCHAR(255) NULL,
  sso_subject     VARCHAR(190) NULL,
  nombre_mostrar  VARCHAR(120) NOT NULL,
  rol             ENUM('admin_cde','consultor','emprendedor') NOT NULL,
  empresa_id      BIGINT UNSIGNED NULL,
  activo          TINYINT(1) NOT NULL DEFAULT 1,
  ultimo_login_at DATETIME(3) NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_usuarios_tenant_id    (tenant_id, id),
  UNIQUE KEY uq_usuarios_tenant_email (tenant_id, email),
  UNIQUE KEY uq_usuarios_tenant_sso   (tenant_id, sso_subject),
  KEY idx_usuarios_rol_activo (tenant_id, rol, activo),
  KEY idx_usuarios_empresa    (tenant_id, empresa_id),
  CONSTRAINT fk_usuarios_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_usuarios_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT ck_usuarios_credencial CHECK (password_hash IS NOT NULL OR sso_subject IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Cuentas de acceso (admin_cde, consultor, emprendedor)';

CREATE TABLE refresh_tokens (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  usuario_id  BIGINT UNSIGNED NOT NULL,
  token_hash  CHAR(64) NOT NULL,
  expira_at   DATETIME(3) NOT NULL,
  revocado_at DATETIME(3) NULL,
  ip          VARBINARY(16) NULL,
  user_agent  VARCHAR(255) NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_refresh_token_hash (token_hash),
  KEY idx_refresh_usuario_vigencia (tenant_id, usuario_id, revocado_at, expira_at),
  KEY idx_refresh_expira (expira_at),
  CONSTRAINT fk_refresh_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_refresh_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id) ON DELETE CASCADE
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE auditoria_seguridad (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  usuario_id  BIGINT UNSIGNED NULL,
  accion      VARCHAR(60) NOT NULL,
  entidad     VARCHAR(60) NULL,
  entidad_id  BIGINT UNSIGNED NULL,
  detalle     JSON NULL,
  ip          VARBINARY(16) NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_audit_tenant_fecha   (tenant_id, created_at),
  KEY idx_audit_usuario_fecha  (tenant_id, usuario_id, created_at),
  KEY idx_audit_entidad        (tenant_id, entidad, entidad_id),
  KEY idx_audit_accion_fecha   (tenant_id, accion, created_at),
  CONSTRAINT fk_audit_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_audit_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE personas (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id             INT UNSIGNED NOT NULL,
  tipo_documento_id     SMALLINT UNSIGNED NULL,     /* NULL permitido */
  numero_documento      VARCHAR(25) NULL,           /* NULL permitido */
  nombres               VARCHAR(100) NOT NULL,
  apellidos             VARCHAR(100) NOT NULL,
  email                 VARCHAR(190) NULL,
  telefono              VARCHAR(25) NULL,
  empresa_id            BIGINT UNSIGNED NULL,
  es_contacto_principal TINYINT(1) NOT NULL DEFAULT 0,
  vinculo_unab_id       SMALLINT UNSIGNED NULL,
  habeas_data_at        DATETIME(3) NULL,
  deleted_at            DATETIME(3) NULL,
  contacto_empresa_key  BIGINT UNSIGNED GENERATED ALWAYS AS
                        (IF(es_contacto_principal = 1 AND deleted_at IS NULL, empresa_id, NULL)) VIRTUAL,
  created_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_personas_tenant_id        (tenant_id, id),
  UNIQUE KEY uq_personas_documento        (tenant_id, tipo_documento_id, numero_documento),
  UNIQUE KEY uq_personas_contacto_empresa (tenant_id, contacto_empresa_key),
  KEY idx_personas_empresa  (tenant_id, empresa_id),
  KEY idx_personas_vinculo  (tenant_id, vinculo_unab_id),
  KEY idx_personas_nombre   (tenant_id, apellidos, nombres),
  KEY idx_personas_email    (tenant_id, email),
  CONSTRAINT fk_personas_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_personas_tipodoc FOREIGN KEY (tipo_documento_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_personas_vinculo FOREIGN KEY (vinculo_unab_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_personas_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE empresa_alias (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id          INT UNSIGNED NOT NULL,
  empresa_id         BIGINT UNSIGNED NOT NULL,
  alias              VARCHAR(200) NOT NULL,
  alias_normalizado  VARCHAR(200) NOT NULL,
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_alias_normalizado (tenant_id, alias_normalizado),
  KEY idx_alias_empresa (tenant_id, empresa_id),
  CONSTRAINT fk_alias_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_alias_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id) ON DELETE CASCADE
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

/* ---------------------------------------------------------------------------
   4. INTERACCIONES · EXPEDIENTE 360
   --------------------------------------------------------------------------- */

CREATE TABLE proyectos_aula (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id           INT UNSIGNED NOT NULL,
  empresa_id          BIGINT UNSIGNED NOT NULL,
  docente_persona_id  BIGINT UNSIGNED NOT NULL,
  asignatura          VARCHAR(150) NOT NULL,
  titulo              VARCHAR(200) NOT NULL,
  fecha_inicio        DATE NOT NULL,
  fecha_fin           DATE NULL,
  created_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_proyectos_tenant_id (tenant_id, id),
  KEY idx_proyectos_empresa_fecha (tenant_id, empresa_id, fecha_inicio),
  KEY idx_proyectos_docente       (tenant_id, docente_persona_id),
  CONSTRAINT fk_proyectos_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_proyectos_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_proyectos_docente FOREIGN KEY (tenant_id, docente_persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT ck_proyectos_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE proyecto_estudiantes (
  tenant_id    INT UNSIGNED NOT NULL,
  proyecto_id  BIGINT UNSIGNED NOT NULL,
  persona_id   BIGINT UNSIGNED NOT NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (proyecto_id, persona_id),
  KEY idx_proy_est_persona (tenant_id, persona_id),
  CONSTRAINT fk_proy_est_tenant   FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_proy_est_proyecto FOREIGN KEY (tenant_id, proyecto_id) REFERENCES proyectos_aula (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_proy_est_persona  FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE misiones (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  tipo             ENUM('pildora','quiz','meta','mentoria','reto_semanal') NOT NULL,
  eje_id           SMALLINT UNSIGNED NULL,
  nivel_minimo_id  SMALLINT UNSIGNED NULL,
  titulo           VARCHAR(150) NOT NULL,
  pasos            JSON NOT NULL,
  xp_recompensa    SMALLINT UNSIGNED NOT NULL,
  duracion_min     SMALLINT UNSIGNED NULL,
  vigente_hasta    DATETIME(3) NULL,
  activa           TINYINT(1) NOT NULL DEFAULT 1,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_misiones_tenant_id (tenant_id, id),
  KEY idx_misiones_activa_tipo (tenant_id, activa, tipo),
  KEY idx_misiones_eje         (tenant_id, eje_id),
  KEY idx_misiones_nivel       (nivel_minimo_id),
  CONSTRAINT fk_misiones_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_misiones_eje    FOREIGN KEY (eje_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_misiones_nivel  FOREIGN KEY (nivel_minimo_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_misiones_xp CHECK (xp_recompensa > 0)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE citas_asesoria (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id     INT UNSIGNED NOT NULL,
  empresa_id    BIGINT UNSIGNED NOT NULL,
  consultor_id  BIGINT UNSIGNED NOT NULL,
  area_id       SMALLINT UNSIGNED NOT NULL,
  estado        ENUM('pendiente','confirmada','realizada','cancelada') NOT NULL DEFAULT 'pendiente',
  inicio_at     DATETIME(3) NOT NULL,
  fin_at        DATETIME(3) NOT NULL,
  mision_id     BIGINT UNSIGNED NULL,
  notas         TEXT NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_citas_consultor_inicio (tenant_id, consultor_id, inicio_at),
  KEY idx_citas_empresa_inicio   (tenant_id, empresa_id, inicio_at),
  KEY idx_citas_estado_inicio    (tenant_id, estado, inicio_at),
  KEY idx_citas_mision           (tenant_id, mision_id),
  KEY idx_citas_area             (area_id),
  CONSTRAINT fk_citas_tenant    FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_citas_empresa   FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_citas_consultor FOREIGN KEY (tenant_id, consultor_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT fk_citas_mision    FOREIGN KEY (tenant_id, mision_id) REFERENCES misiones (tenant_id, id),
  CONSTRAINT fk_citas_area      FOREIGN KEY (area_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_citas_horario CHECK (fin_at > inicio_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE eventos (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id      INT UNSIGNED NOT NULL,
  tipo_id        SMALLINT UNSIGNED NOT NULL,
  nombre_evento  VARCHAR(200) NOT NULL,
  estado         ENUM('borrador','confirmado','realizado','cancelado') NOT NULL DEFAULT 'borrador',
  inicio_at      DATETIME(3) NOT NULL,
  fin_at         DATETIME(3) NOT NULL,
  lugar          VARCHAR(200) NULL,
  xp_checkin     SMALLINT UNSIGNED NOT NULL DEFAULT 50,
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_eventos_tenant_id (tenant_id, id),
  KEY idx_eventos_estado_inicio (tenant_id, estado, inicio_at),
  KEY idx_eventos_tipo          (tipo_id),
  CONSTRAINT fk_eventos_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_eventos_tipo   FOREIGN KEY (tipo_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_eventos_horario CHECK (fin_at > inicio_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE evento_convocatorias (
  tenant_id   INT UNSIGNED NOT NULL,
  evento_id   BIGINT UNSIGNED NOT NULL,
  empresa_id  BIGINT UNSIGNED NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (evento_id, empresa_id),
  KEY idx_convoc_empresa (tenant_id, empresa_id),
  CONSTRAINT fk_convoc_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_convoc_evento  FOREIGN KEY (tenant_id, evento_id) REFERENCES eventos (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_convoc_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE evento_inscripciones (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  evento_id       BIGINT UNSIGNED NOT NULL,
  empresa_id      BIGINT UNSIGNED NOT NULL,
  persona_id      BIGINT UNSIGNED NOT NULL,
  checkin_at      DATETIME(3) NULL,
  checkin_metodo  ENUM('qr','manual') NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_inscripcion_evento_persona (evento_id, persona_id),
  KEY idx_inscr_empresa_evento (tenant_id, empresa_id, evento_id),
  KEY idx_inscr_evento_checkin (tenant_id, evento_id, checkin_at),
  KEY idx_inscr_persona        (tenant_id, persona_id),
  CONSTRAINT fk_inscr_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_inscr_evento  FOREIGN KEY (tenant_id, evento_id) REFERENCES eventos (tenant_id, id),
  CONSTRAINT fk_inscr_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_inscr_persona FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT ck_inscr_checkin CHECK ((checkin_at IS NULL AND checkin_metodo IS NULL)
                                  OR (checkin_at IS NOT NULL AND checkin_metodo IS NOT NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE autodiagnosticos (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  empresa_id       BIGINT UNSIGNED NOT NULL,
  tipo             ENUM('inicial','seguimiento') NOT NULL,
  aplicado_por_id  BIGINT UNSIGNED NULL,
  aplicado_at      DATETIME(3) NOT NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_autodiag_tenant_id (tenant_id, id),
  KEY idx_autodiag_empresa_tipo_fecha (tenant_id, empresa_id, tipo, aplicado_at),
  KEY idx_autodiag_aplicador (tenant_id, aplicado_por_id),
  CONSTRAINT fk_autodiag_tenant    FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_autodiag_empresa   FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_autodiag_aplicador FOREIGN KEY (tenant_id, aplicado_por_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE autodiagnostico_respuestas (
  tenant_id           INT UNSIGNED NOT NULL,
  autodiagnostico_id  BIGINT UNSIGNED NOT NULL,
  eje_id              SMALLINT UNSIGNED NOT NULL,
  puntaje             TINYINT UNSIGNED NOT NULL,
  brecha              VARCHAR(255) NULL,
  created_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (autodiagnostico_id, eje_id),
  KEY idx_diag_resp_eje_puntaje (tenant_id, eje_id, puntaje),
  CONSTRAINT fk_diag_resp_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_diag_resp_diag   FOREIGN KEY (tenant_id, autodiagnostico_id) REFERENCES autodiagnosticos (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_diag_resp_eje    FOREIGN KEY (eje_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_diag_resp_puntaje CHECK (puntaje <= 100)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE planes_accion (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id            INT UNSIGNED NOT NULL,
  empresa_id           BIGINT UNSIGNED NOT NULL,
  eje_id               SMALLINT UNSIGNED NULL,
  autodiagnostico_id   BIGINT UNSIGNED NULL,
  titulo               VARCHAR(200) NOT NULL,
  estado               ENUM('pendiente','en_ejecucion','en_validacion_cde','completado_con_impacto')
                       NOT NULL DEFAULT 'pendiente',
  orden_kanban         INT UNSIGNED NOT NULL DEFAULT 0,
  progreso             TINYINT UNSIGNED NOT NULL DEFAULT 0,
  responsable_id       BIGINT UNSIGNED NOT NULL,
  fecha_limite         DATE NOT NULL,
  firmado_at           DATETIME(3) NULL,
  impacto_descripcion  VARCHAR(200) NULL,
  impacto_validado_at  DATETIME(3) NULL,
  created_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_planes_kanban      (tenant_id, estado, orden_kanban),
  KEY idx_planes_vencimiento (tenant_id, fecha_limite, estado),
  KEY idx_planes_empresa     (tenant_id, empresa_id, estado),
  KEY idx_planes_responsable (tenant_id, responsable_id, estado),
  KEY idx_planes_diag        (tenant_id, autodiagnostico_id),
  KEY idx_planes_eje         (eje_id),
  CONSTRAINT fk_planes_tenant      FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_planes_empresa     FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_planes_diag        FOREIGN KEY (tenant_id, autodiagnostico_id) REFERENCES autodiagnosticos (tenant_id, id),
  CONSTRAINT fk_planes_responsable FOREIGN KEY (tenant_id, responsable_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT fk_planes_eje         FOREIGN KEY (eje_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_planes_progreso CHECK (progreso <= 100),
  CONSTRAINT ck_planes_impacto  CHECK (estado <> 'completado_con_impacto' OR impacto_descripcion IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

/* ---------------------------------------------------------------------------
   5. GAMIFICACIÓN
   --------------------------------------------------------------------------- */

CREATE TABLE empresa_misiones (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id           INT UNSIGNED NOT NULL,
  empresa_id          BIGINT UNSIGNED NOT NULL,
  mision_id           BIGINT UNSIGNED NOT NULL,
  estado              ENUM('en_progreso','completada') NOT NULL DEFAULT 'en_progreso',
  pasos_completados   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  recomendada_por_ia  TINYINT(1) NOT NULL DEFAULT 0,
  completada_at       DATETIME(3) NULL,
  xp_reclamado_at     DATETIME(3) NULL,
  created_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_emp_mision (empresa_id, mision_id),
  KEY idx_emp_mision_estado (tenant_id, empresa_id, estado),
  KEY idx_emp_mision_mision (tenant_id, mision_id),
  CONSTRAINT fk_emp_mision_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_emp_mision_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_emp_mision_mision  FOREIGN KEY (tenant_id, mision_id) REFERENCES misiones (tenant_id, id),
  CONSTRAINT ck_emp_mision_estado CHECK ((estado = 'completada') = (completada_at IS NOT NULL)),
  CONSTRAINT ck_emp_mision_xp CHECK (xp_reclamado_at IS NULL OR completada_at IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE xp_movimientos (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  empresa_id  BIGINT UNSIGNED NOT NULL,
  persona_id  BIGINT UNSIGNED NULL,
  origen      ENUM('mision','checkin_evento','plan_completado','ajuste') NOT NULL,
  origen_id   BIGINT UNSIGNED NULL,
  puntos      INT NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_xp_origen (empresa_id, origen, origen_id),
  KEY idx_xp_empresa_fecha (tenant_id, empresa_id, created_at, puntos),
  KEY idx_xp_persona       (tenant_id, persona_id),
  CONSTRAINT fk_xp_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_xp_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_xp_persona FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT ck_xp_puntos CHECK (puntos <> 0)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE empresa_medallas (
  tenant_id    INT UNSIGNED NOT NULL,
  empresa_id   BIGINT UNSIGNED NOT NULL,
  medalla_id   SMALLINT UNSIGNED NOT NULL,
  obtenida_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (empresa_id, medalla_id),
  KEY idx_emp_medalla (tenant_id, medalla_id),
  CONSTRAINT fk_emp_medalla_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_emp_medalla_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_emp_medalla_medalla FOREIGN KEY (medalla_id) REFERENCES catalogo_items (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

/* ---------------------------------------------------------------------------
   6. AUTOMATIZACIONES
   --------------------------------------------------------------------------- */
CREATE TABLE reglas_automatizacion (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  nombre           VARCHAR(150) NOT NULL,
  estado           ENUM('activo','pausado','borrador') NOT NULL DEFAULT 'borrador',
  definicion       JSON NOT NULL,
  creada_con_ia    TINYINT(1) NOT NULL DEFAULT 0,
  n8n_workflow_id  VARCHAR(80) NULL,
  creada_por_id    BIGINT UNSIGNED NOT NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_reglas_nombre (tenant_id, nombre),
  KEY idx_reglas_estado (tenant_id, estado),
  KEY idx_reglas_autor  (tenant_id, creada_por_id),
  CONSTRAINT fk_reglas_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_reglas_autor  FOREIGN KEY (tenant_id, creada_por_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

/* ---------------------------------------------------------------------------
   7. INGESTA Y DEDUPLICACIÓN
   --------------------------------------------------------------------------- */
CREATE TABLE migracion_lotes (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id              INT UNSIGNED NOT NULL,
  usuario_id             BIGINT UNSIGNED NOT NULL,
  archivo_nombre         VARCHAR(190) NULL,
  estado                 ENUM('subir','revisar','confirmado') NOT NULL DEFAULT 'subir',
  total_atenciones       INT UNSIGNED NOT NULL DEFAULT 0,
  total_empresas_unicas  INT UNSIGNED NOT NULL DEFAULT 0,
  filas_leidas           INT UNSIGNED NOT NULL DEFAULT 0,
  confirmado_at          DATETIME(3) NULL,
  created_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_lotes_tenant_id (tenant_id, id),
  KEY idx_lotes_estado_fecha (tenant_id, estado, created_at),
  KEY idx_lotes_usuario      (tenant_id, usuario_id),
  CONSTRAINT fk_lotes_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_lotes_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE atenciones (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id             INT UNSIGNED NOT NULL,
  lote_id               BIGINT UNSIGNED NOT NULL,
  codigo_externo        VARCHAR(30)  NOT NULL,
  empresa_id            BIGINT UNSIGNED NOT NULL,
  persona_id            BIGINT UNSIGNED NULL,
  empresa_nombre_origen VARCHAR(200) NOT NULL,
  nit_origen            VARCHAR(30)  NOT NULL,
  sector_id             SMALLINT UNSIGNED NULL,
  tamano_id             SMALLINT UNSIGNED NULL,
  formalizacion_id      SMALLINT UNSIGNED NULL,
  vinculo_unab_id       SMALLINT UNSIGNED NULL,
  brecha_id             SMALLINT UNSIGNED NULL,
  periodo               CHAR(6) NOT NULL,
  created_at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_atenciones_codigo (tenant_id, codigo_externo),
  KEY idx_atenciones_empresa (tenant_id, empresa_id),
  KEY idx_atenciones_periodo (tenant_id, periodo),
  KEY idx_atenciones_lote    (tenant_id, lote_id),
  KEY idx_atenciones_brecha  (brecha_id),
  CONSTRAINT fk_atenciones_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_atenciones_lote    FOREIGN KEY (tenant_id, lote_id) REFERENCES migracion_lotes (tenant_id, id),
  CONSTRAINT fk_atenciones_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_atenciones_persona FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT fk_atenciones_sector  FOREIGN KEY (sector_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_tamano  FOREIGN KEY (tamano_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_formal  FOREIGN KEY (formalizacion_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_vinculo FOREIGN KEY (vinculo_unab_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_atenciones_brecha  FOREIGN KEY (brecha_id) REFERENCES catalogo_items (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE duplicados_candidatos (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  lote_id          BIGINT UNSIGNED NULL,
  empresa_a_id     BIGINT UNSIGNED NOT NULL,
  empresa_b_id     BIGINT UNSIGNED NOT NULL,
  score            DECIMAL(5,4) NOT NULL,
  estado           ENUM('por_revisar','fusionado','descartado') NOT NULL DEFAULT 'por_revisar',
  snapshot_previo  JSON NULL,
  resuelto_por_id  BIGINT UNSIGNED NULL,
  resuelto_at      DATETIME(3) NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_dup_par (tenant_id, empresa_a_id, empresa_b_id),
  KEY idx_dup_cola      (tenant_id, estado, score DESC),
  KEY idx_dup_lote      (tenant_id, lote_id),
  KEY idx_dup_b         (tenant_id, empresa_b_id),
  KEY idx_dup_resolutor (tenant_id, resuelto_por_id),
  CONSTRAINT fk_dup_tenant    FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_dup_lote      FOREIGN KEY (tenant_id, lote_id) REFERENCES migracion_lotes (tenant_id, id),
  CONSTRAINT fk_dup_empresa_a FOREIGN KEY (tenant_id, empresa_a_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_dup_empresa_b FOREIGN KEY (tenant_id, empresa_b_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_dup_resolutor FOREIGN KEY (tenant_id, resuelto_por_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT ck_dup_score CHECK (score >= 0 AND score <= 1),
  CONSTRAINT ck_dup_resolucion CHECK ((estado = 'por_revisar' AND resuelto_at IS NULL)
                                   OR (estado <> 'por_revisar' AND resuelto_at IS NOT NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

/* ---------------------------------------------------------------------------
   8. IA Y SERVER-DRIVEN UI
   --------------------------------------------------------------------------- */
CREATE TABLE ia_consultas (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  usuario_id      BIGINT UNSIGNED NOT NULL,
  empresa_id      BIGINT UNSIGNED NULL,
  funcion         ENUM('pregunta_datos','hallazgos','segmentacion','regla','sintesis','mision') NOT NULL,
  modelo          VARCHAR(60) NOT NULL,
  prompt          TEXT NOT NULL,
  respuesta       JSON NULL,
  valida          TINYINT(1) NOT NULL DEFAULT 0,
  tokens_entrada  INT UNSIGNED NOT NULL DEFAULT 0,
  tokens_salida   INT UNSIGNED NOT NULL DEFAULT 0,
  latencia_ms     INT UNSIGNED NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_ia_usuario_fecha (tenant_id, usuario_id, created_at),
  KEY idx_ia_funcion_fecha (tenant_id, funcion, created_at),
  KEY idx_ia_cache_empresa (tenant_id, empresa_id, funcion, created_at),
  CONSTRAINT fk_ia_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_ia_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT fk_ia_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

CREATE TABLE sdui_esquemas (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  ruta        VARCHAR(120) NOT NULL,
  rol         ENUM('admin_cde','consultor','emprendedor') NULL,
  rol_key     VARCHAR(20) GENERATED ALWAYS AS (IFNULL(rol, '*')) VIRTUAL,
  version     SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  esquema     JSON NOT NULL,
  activo      TINYINT(1) NOT NULL DEFAULT 0,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_sdui_version (tenant_id, ruta, rol_key, version),
  KEY idx_sdui_vigente (tenant_id, ruta, activo),
  CONSTRAINT fk_sdui_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

SET FOREIGN_KEY_CHECKS = 1;

/* ---------------------------------------------------------------------------
   9. FUNCIÓN Y TRIGGERS (Incluye las validaciones que MySQL 8.0 prohíbe en CHECK+FK)
   --------------------------------------------------------------------------- */
DELIMITER $$

CREATE FUNCTION fn_periodo(d DATETIME) RETURNS CHAR(6)
  DETERMINISTIC NO SQL
BEGIN
  RETURN CONCAT(YEAR(d), '-', IF(MONTH(d) <= 6, 1, 2));
END$$

/* Validación de fusión en empresas (Evita ERROR 3823 de MySQL 8.0 en CHECK + FK) */
CREATE TRIGGER trg_empresas_bi_validacion
BEFORE INSERT ON empresas FOR EACH ROW
BEGIN
  IF NEW.estado = 'fusionada' AND NEW.fusionada_en_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Una empresa fusionada requiere fusionada_en_id';
  END IF;
END$$

CREATE TRIGGER trg_empresas_bu_vector
BEFORE UPDATE ON empresas FOR EACH ROW
BEGIN
  IF NEW.estado = 'fusionada' AND NEW.fusionada_en_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Una empresa fusionada requiere fusionada_en_id';
  END IF;
  IF NOT (NEW.razon_social <=> OLD.razon_social
      AND NEW.nombre_comercial <=> OLD.nombre_comercial
      AND NEW.sector_id <=> OLD.sector_id
      AND NEW.municipio <=> OLD.municipio)
     AND (NEW.vector_sync <=> OLD.vector_sync) THEN
    SET NEW.vector_sync = 'pendiente';
  END IF;
END$$

/* Validación de rol emprendedor con empresa_id (Evita ERROR 3823 de MySQL 8.0) */
CREATE TRIGGER trg_usuarios_bi_validacion
BEFORE INSERT ON usuarios FOR EACH ROW
BEGIN
  IF NEW.rol = 'emprendedor' AND NEW.empresa_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El rol emprendedor requiere empresa_id asociado';
  END IF;
END$$

CREATE TRIGGER trg_usuarios_bu_validacion
BEFORE UPDATE ON usuarios FOR EACH ROW
BEGIN
  IF NEW.rol = 'emprendedor' AND NEW.empresa_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El rol emprendedor requiere empresa_id asociado';
  END IF;
END$$

/* Orden automático y validación en duplicados_candidatos (Evita ERROR 3823 de MySQL 8.0) */
CREATE TRIGGER trg_dup_bi_orden
BEFORE INSERT ON duplicados_candidatos FOR EACH ROW
BEGIN
  DECLARE tmp_id BIGINT UNSIGNED;
  IF NEW.empresa_a_id = NEW.empresa_b_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'empresa_a_id y empresa_b_id no pueden ser la misma empresa';
  END IF;
  IF NEW.empresa_a_id > NEW.empresa_b_id THEN
    SET tmp_id = NEW.empresa_a_id;
    SET NEW.empresa_a_id = NEW.empresa_b_id;
    SET NEW.empresa_b_id = tmp_id;
  END IF;
END$$

/* Libro mayor de XP inmutable */
CREATE TRIGGER trg_xp_bu_inmutable
BEFORE UPDATE ON xp_movimientos FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'xp_movimientos es inmutable: registre un movimiento de ajuste';
END$$

CREATE TRIGGER trg_xp_bd_inmutable
BEFORE DELETE ON xp_movimientos FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'xp_movimientos es inmutable: registre un movimiento de ajuste';
END$$

/* Bitácora de seguridad append-only */
CREATE TRIGGER trg_audit_bu_inmutable
BEFORE UPDATE ON auditoria_seguridad FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'auditoria_seguridad es append-only';
END$$

CREATE TRIGGER trg_audit_bd_inmutable
BEFORE DELETE ON auditoria_seguridad FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'auditoria_seguridad es append-only';
END$$

DELIMITER ;

/* ---------------------------------------------------------------------------
   10. VISTAS DERIVADAS (Corregidas: ev.nombre_evento y LEFT JOIN para sin sector)
   --------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW vw_empresa_resumen AS
SELECT t.*,
       IF(t.ficha_pct >= 80, 'completa', 'incompleta') AS ficha_estado
FROM (
  SELECT e.tenant_id,
         e.id AS empresa_id,
         e.nombre_comercial,
         e.sector_id,
         e.estado,
         ROUND(100 * (
             (e.nit IS NOT NULL) + (e.sector_id IS NOT NULL) + (e.tamano_id IS NOT NULL)
           + (e.municipio IS NOT NULL) + (e.email_contacto IS NOT NULL) + (e.telefono IS NOT NULL)
           + (e.numero_empleados IS NOT NULL)
           + EXISTS (SELECT 1 FROM personas p
                      WHERE p.tenant_id = e.tenant_id AND p.empresa_id = e.id
                        AND p.es_contacto_principal = 1 AND p.deleted_at IS NULL)
         ) / 8) AS ficha_pct,
         EXISTS (SELECT 1 FROM personas p
                   JOIN catalogo_items v ON v.id = p.vinculo_unab_id
                  WHERE p.tenant_id = e.tenant_id AND p.empresa_id = e.id
                    AND p.deleted_at IS NULL AND v.codigo <> 'ninguno') AS es_comunidad_unab
  FROM empresas e
  WHERE e.deleted_at IS NULL AND e.estado <> 'fusionada'
) t;

CREATE OR REPLACE VIEW vw_expediente_360 AS
SELECT p.tenant_id, p.empresa_id, 
       CONVERT('proyecto' USING utf8mb4) COLLATE utf8mb4_unicode_ci AS tipo,
       CAST(p.fecha_inicio AS DATETIME(3)) AS fecha,
       CONVERT(p.titulo USING utf8mb4) COLLATE utf8mb4_unicode_ci AS titulo, 
       CONVERT(p.asignatura USING utf8mb4) COLLATE utf8mb4_unicode_ci AS detalle, 
       p.id AS ref_id
FROM proyectos_aula p

UNION ALL

SELECT c.tenant_id, c.empresa_id, 
       CONVERT('cita' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       c.inicio_at,
       CONVERT(CONCAT('Asesoría · ', a.nombre) USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       CONVERT(CAST(c.estado AS CHAR) USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       c.id
FROM citas_asesoria c
JOIN catalogo_items a ON a.id = c.area_id

UNION ALL

SELECT i.tenant_id, i.empresa_id, 
       CONVERT('evento' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       COALESCE(i.checkin_at, ev.inicio_at),
       CONVERT(ev.nombre_evento USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       CONVERT(IF(i.checkin_at IS NULL, 'Inscrito', 'Asistió') USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       i.id
FROM evento_inscripciones i
JOIN eventos ev ON ev.tenant_id = i.tenant_id AND ev.id = i.evento_id

UNION ALL

SELECT d.tenant_id, d.empresa_id, 
       CONVERT('diagnostico' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       d.aplicado_at,
       CONVERT(CONCAT('Diagnóstico ', d.tipo) USING utf8mb4) COLLATE utf8mb4_unicode_ci,
       CONVERT((SELECT GROUP_CONCAT(r.brecha SEPARATOR '; ')
          FROM autodiagnostico_respuestas r
         WHERE r.autodiagnostico_id = d.id AND r.brecha IS NOT NULL) USING utf8mb4) COLLATE utf8mb4_unicode_ci,
       d.id
FROM autodiagnosticos d

UNION ALL

SELECT pa.tenant_id, pa.empresa_id, 
       CONVERT('plan' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       pa.firmado_at,
       CONVERT('Plan de acción firmado' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       CONVERT(pa.titulo USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       pa.id
FROM planes_accion pa
WHERE pa.firmado_at IS NOT NULL

UNION ALL

SELECT pa.tenant_id, pa.empresa_id, 
       CONVERT('impacto' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       pa.impacto_validado_at,
       CONVERT('Validación CDE' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       CONVERT(pa.impacto_descripcion USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       pa.id
FROM planes_accion pa
WHERE pa.impacto_validado_at IS NOT NULL

UNION ALL

SELECT at.tenant_id, at.empresa_id, 
       CONVERT('atencion' USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       at.created_at,
       CONVERT(CONCAT('Atención ', at.codigo_externo, ' (', at.periodo, ')') USING utf8mb4) COLLATE utf8mb4_unicode_ci,
       CONVERT(CONCAT('Brecha: ', COALESCE(b.nombre, 'Sin especificar')) USING utf8mb4) COLLATE utf8mb4_unicode_ci, 
       at.id
FROM atenciones at
LEFT JOIN catalogo_items b ON b.id = at.brecha_id;

CREATE OR REPLACE VIEW vw_empresa_gamificacion AS
SELECT t.*,
       (SELECT n.codigo FROM catalogo_items n
         WHERE n.tipo = 'nivel' AND n.activo = 1 AND (n.tenant_id = t.tenant_id OR n.tenant_id IS NULL)
           AND n.valor <= t.xp_total ORDER BY n.valor DESC LIMIT 1) AS nivel_actual,
       (SELECT n.nombre FROM catalogo_items n
         WHERE n.tipo = 'nivel' AND n.activo = 1 AND (n.tenant_id = t.tenant_id OR n.tenant_id IS NULL)
           AND n.valor <= t.xp_total ORDER BY n.valor DESC LIMIT 1) AS nivel_nombre,
       (SELECT n.valor FROM catalogo_items n
         WHERE n.tipo = 'nivel' AND n.activo = 1 AND (n.tenant_id = t.tenant_id OR n.tenant_id IS NULL)
           AND n.valor > t.xp_total ORDER BY n.valor ASC LIMIT 1) AS xp_siguiente_nivel
FROM (
  SELECT e.tenant_id, e.id AS empresa_id,
         COALESCE((SELECT SUM(x.puntos) FROM xp_movimientos x
                    WHERE x.tenant_id = e.tenant_id AND x.empresa_id = e.id), 0) AS xp_total,
         COALESCE((SELECT SUM(x.puntos) FROM xp_movimientos x
                    WHERE x.tenant_id = e.tenant_id AND x.empresa_id = e.id
                      AND x.created_at >= UTC_TIMESTAMP(3) - INTERVAL 7 DAY), 0) AS xp_semana,
         (SELECT COUNT(DISTINCT DATE(x.created_at)) FROM xp_movimientos x
           WHERE x.tenant_id = e.tenant_id AND x.empresa_id = e.id
             AND x.created_at >= UTC_TIMESTAMP(3) - INTERVAL 7 DAY) AS dias_activos_7d,
         (SELECT COUNT(*) FROM empresa_medallas m
           WHERE m.tenant_id = e.tenant_id AND m.empresa_id = e.id) AS medallas
  FROM empresas e
  WHERE e.deleted_at IS NULL AND e.estado <> 'fusionada'
) t;

CREATE OR REPLACE VIEW vw_evento_embudo AS
SELECT t.*,
       ROUND(100 * t.asistentes / NULLIF(t.convocados, 0), 1) AS pct_asistencia_sobre_convocados
FROM (
  SELECT ev.tenant_id, ev.id AS evento_id, ev.nombre_evento AS titulo, ev.estado,
         (SELECT COUNT(*) FROM evento_convocatorias c WHERE c.evento_id = ev.id) AS convocados,
         (SELECT COUNT(*) FROM evento_inscripciones i WHERE i.evento_id = ev.id) AS inscritos,
         (SELECT COUNT(*) FROM evento_inscripciones i
           WHERE i.evento_id = ev.id AND i.checkin_at IS NOT NULL) AS asistentes
  FROM eventos ev
) t;

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
) a
JOIN empresas e ON e.tenant_id = a.tenant_id AND e.id = a.empresa_id AND e.deleted_at IS NULL
LEFT JOIN catalogo_items s ON s.id = e.sector_id
GROUP BY a.tenant_id, a.periodo, s.id, COALESCE(s.nombre, 'Sin sector');

CREATE OR REPLACE VIEW vw_planes_accion_estado AS
SELECT p.tenant_id, p.id AS plan_id, p.empresa_id, e.nombre_comercial AS empresa,
       p.titulo, p.estado, p.progreso, p.responsable_id, p.fecha_limite,
       (p.estado <> 'completado_con_impacto' AND p.fecha_limite < CURDATE()) AS vencido
FROM planes_accion p
JOIN empresas e ON e.tenant_id = p.tenant_id AND e.id = p.empresa_id;

/* ---------------------------------------------------------------------------
   11. SEED INICIAL
   --------------------------------------------------------------------------- */
INSERT INTO tenants (slug, nombre, plan) VALUES ('unab-cde', 'Centro de Desarrollo Empresarial UNAB', 'enterprise');

INSERT INTO catalogo_items (tenant_id, tipo, codigo, nombre, valor, orden) VALUES
 (NULL,'sector','alimentos','Alimentos',NULL,1),
 (NULL,'sector','comercio','Comercio',NULL,2),
 (NULL,'sector','servicios','Servicios',NULL,3),
 (NULL,'sector','manufactura','Manufactura',NULL,4),
 (NULL,'sector','turismo','Turismo',NULL,5),
 (NULL,'sector','agropecuario','Agropecuario',NULL,6),
 (NULL,'sector','tecnologia','Tecnología',NULL,7),
 (NULL,'sector','construccion','Construcción',NULL,8),
 (NULL,'sector','salud','Salud',NULL,9),
 (NULL,'sector','educacion','Educación',NULL,10),
 (NULL,'sector','transporte','Transporte y logística',NULL,11),
 (NULL,'sector','otros','Otros',NULL,12),

 (NULL,'tamano','idea','Idea / emprendimiento naciente',NULL,1),
 (NULL,'tamano','micro','Microempresa',NULL,2),
 (NULL,'tamano','pequena','Pequeña',NULL,3),
 (NULL,'tamano','mediana','Mediana',NULL,4),
 (NULL,'tamano','grande','Grande',NULL,5),

 (NULL,'vinculo_unab','estudiante','Estudiante',NULL,1),
 (NULL,'vinculo_unab','egresado','Egresado',NULL,2),
 (NULL,'vinculo_unab','docente','Docente',NULL,3),
 (NULL,'vinculo_unab','colaborador','Colaborador administrativo',NULL,4),
 (NULL,'vinculo_unab','ninguno','Sin vínculo',NULL,5),

 (NULL,'tipo_documento','CC','Cédula de ciudadanía',NULL,1),
 (NULL,'tipo_documento','CE','Cédula de extranjería',NULL,2),
 (NULL,'tipo_documento','NIT','NIT',NULL,3),
 (NULL,'tipo_documento','PAS','Pasaporte',NULL,4),
 (NULL,'tipo_documento','TI','Tarjeta de identidad',NULL,5),

 (NULL,'eje_diagnostico','estrategia','Estrategia',NULL,1),
 (NULL,'eje_diagnostico','normativa','Normativa',NULL,2),
 (NULL,'eje_diagnostico','mercadeo','Mercadeo',NULL,3),
 (NULL,'eje_diagnostico','financiera','Financiera',NULL,4),
 (NULL,'eje_diagnostico','digital','Digital',NULL,5),
 (NULL,'eje_diagnostico','productividad','Productividad',NULL,6),

 (NULL,'area_asesoria','costos','Costos',NULL,1),
 (NULL,'area_asesoria','marca','Marca',NULL,2),
 (NULL,'area_asesoria','calidad','Calidad',NULL,3),
 (NULL,'area_asesoria','ventas','Ventas',NULL,4),
 (NULL,'area_asesoria','inventario','Inventario',NULL,5),
 (NULL,'area_asesoria','finanzas','Finanzas',NULL,6),
 (NULL,'area_asesoria','oferta','Oferta de valor',NULL,7),

 (NULL,'tipo_evento','taller','Taller',NULL,1),
 (NULL,'tipo_evento','feria','Feria',NULL,2),
 (NULL,'tipo_evento','capacitacion','Capacitación',NULL,3),
 (NULL,'tipo_evento','networking','Networking',NULL,4),

 (NULL,'nivel','1','Empresa Semilla',0,1),
 (NULL,'nivel','2','Empresa en Marcha',500,2),
 (NULL,'nivel','3','Empresa en Tracción',1000,3),
 (NULL,'nivel','4','Empresa Consolidada',2000,4),
 (NULL,'nivel','5','Empresa Referente',4000,5),

 (NULL,'sector','agroindustria','Agroindustria',NULL,13),
 (NULL,'formalizacion','ninguna','Ninguna',NULL,1),
 (NULL,'formalizacion','rut','RUT',NULL,2),
 (NULL,'formalizacion','rut_camara','RUT + Cámara de Comercio',NULL,3),
 (NULL,'brecha','inventario','Inventario',NULL,1),
 (NULL,'brecha','marketing_digital','Marketing Digital',NULL,2),
 (NULL,'brecha','mercadeo','Mercadeo',NULL,3),
 (NULL,'brecha','calidad','Calidad',NULL,4),
 (NULL,'brecha','finanzas','Finanzas',NULL,5),
 (NULL,'brecha','costos','Costos',NULL,6),
 (NULL,'brecha','operaciones','Operaciones',NULL,7),
 (NULL,'brecha','ventas','Ventas',NULL,8),
 (NULL,'brecha','formalizacion','Formalización',NULL,9),

 (NULL,'medalla','primer_plan','Primer plan',NULL,1),
 (NULL,'medalla','constante','Constante',NULL,2),
 (NULL,'medalla','despegue','Despegue',NULL,3),
 (NULL,'medalla','lider','Líder',NULL,4),
 (NULL,'medalla','referente','Referente',NULL,5);

SET @t := (SELECT id FROM tenants WHERE slug = 'unab-cde');
SET @eje_fin := (SELECT id FROM catalogo_items WHERE tipo='eje_diagnostico' AND codigo='financiera' AND tenant_id IS NULL);
SET @eje_mer := (SELECT id FROM catalogo_items WHERE tipo='eje_diagnostico' AND codigo='mercadeo'   AND tenant_id IS NULL);
SET @niv4    := (SELECT id FROM catalogo_items WHERE tipo='nivel' AND codigo='4' AND tenant_id IS NULL);

INSERT INTO misiones (tenant_id, tipo, eje_id, nivel_minimo_id, titulo, pasos, xp_recompensa, duracion_min) VALUES
 (@t,'pildora', @eje_fin, NULL,  'Costos en 5 minutos',
  JSON_ARRAY(JSON_OBJECT('orden',1,'titulo','Identifica tus costos fijos'),
             JSON_OBJECT('orden',2,'titulo','Identifica tus costos variables'),
             JSON_OBJECT('orden',3,'titulo','Calcula tu punto de equilibrio')), 150, 5),
 (@t,'quiz',    @eje_mer, NULL,  'Quiz de precios',
  JSON_ARRAY(JSON_OBJECT('orden',1,'titulo','Estrategias de precio'),
             JSON_OBJECT('orden',2,'titulo','Margen vs. markup'),
             JSON_OBJECT('orden',3,'titulo','Caso práctico')), 100, 8),
 (@t,'meta',    NULL,     NULL,  'Subir a 3 clientes',
  JSON_ARRAY(JSON_OBJECT('orden',1,'titulo','Cliente 1'),
             JSON_OBJECT('orden',2,'titulo','Cliente 2'),
             JSON_OBJECT('orden',3,'titulo','Cliente 3')), 200, NULL),
 (@t,'mentoria',NULL,     @niv4, 'Mentoría con experto',
  JSON_ARRAY(JSON_OBJECT('orden',1,'titulo','Agenda tu sesión')), 300, 60);
