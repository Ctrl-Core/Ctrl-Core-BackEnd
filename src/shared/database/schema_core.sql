/* =============================================================================
   CDE UNAB · Plataforma multitenant (B2B SaaS)
   Motor      : MySQL 8.0.19+ (CHECK reales desde 8.0.16, FK compuestas, índices DESC)
   Esquema    : 26 tablas, 3FN, aislamiento por tenant_id
   Secciones  : 0 Base  1 Plataforma  2 Catálogo  3 Maestras  4 Expediente 360
                5 Gamificación  6 Automatización  7 Ingesta/Dedup  8 IA/SDUI
                9 Función+Triggers  10 Vistas  11 Seed  12 Notas de afinamiento

   DECISIONES DE DISEÑO
   - tenant_id en TODA tabla, salvo `tenants` y `catalogo_items` (NULL = global).
   - Aislamiento B2B reforzado por BD: cada tabla núcleo expone UNIQUE (tenant_id,id)
     y las hijas referencian con FK compuesta (tenant_id, x_id). Un registro de un
     tenant NUNCA puede apuntar a datos de otro tenant.
   - FK a `catalogo_items` son simples (el catálogo mezcla globales y por tenant).
   - Datos derivados (progreso, XP total, nivel, % ficha, "vencido", "no asistió",
     "Comunidad UNAB") NO se almacenan: viven en vistas (sección 10).
   - Sin ON DELETE/UPDATE explícito = RESTRICT. CASCADE solo en detalle dependiente.
   - Fechas: DATETIME(3) en UTC. La aplicación convierte a America/Bogota.
   ============================================================================= */

/* ---------------------------------------------------------------------------
   0. BASE DE DATOS Y SESIÓN
   --------------------------------------------------------------------------- */
CREATE DATABASE IF NOT EXISTS ctrl_core_db
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE ctrl_core_db;

SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET time_zone = '-05:00';
SET FOREIGN_KEY_CHECKS = 0;

/* Descomentar para reinstalar desde cero (ORDEN INVERSO de dependencias) */
-- DROP VIEW IF EXISTS vw_planes_accion_estado, vw_dashboard_sector, vw_evento_embudo,
--   vw_empresa_gamificacion, vw_expediente_360, vw_empresa_resumen;
-- DROP TABLE IF EXISTS sdui_esquemas, ia_consultas, duplicados_candidatos, migracion_lotes,
--   reglas_automatizacion, empresa_medallas, xp_movimientos, empresa_misiones,
--   planes_accion, autodiagnostico_respuestas, autodiagnosticos, evento_inscripciones,
--   evento_convocatorias, eventos, citas_asesoria, misiones, proyecto_estudiantes,
--   proyectos_aula, empresa_alias, personas, auditoria_seguridad, refresh_tokens,
--   usuarios, empresas, catalogo_items, tenants;

/* ---------------------------------------------------------------------------
   1. PLATAFORMA Y SEGURIDAD
   --------------------------------------------------------------------------- */

CREATE TABLE tenants (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Cliente B2B (universidad, cámara de comercio)',
  slug        VARCHAR(60)  NOT NULL COMMENT 'Identificador legible/subdominio (ej. unab-cde)',
  nombre      VARCHAR(150) NOT NULL COMMENT 'Nombre de la institución',
  plan        ENUM('starter','pro','enterprise') NOT NULL DEFAULT 'starter' COMMENT 'Tier SaaS (la facturación es roadmap Fase 2)',
  activo      TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '0 = tenant suspendido, bloquea login',
  created_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_tenants_slug (slug),
  CONSTRAINT ck_tenants_slug CHECK (slug REGEXP '^[a-z0-9-]+$')
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Clientes B2B de la plataforma (multitenant)';

/* --------------------------------------------------------------------------- */
CREATE TABLE catalogo_items (
  id          SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NULL COMMENT 'NULL = valor global de la plataforma; con valor = personalización del tenant',
  tenant_key  INT UNSIGNED GENERATED ALWAYS AS (IFNULL(tenant_id, 0)) STORED COMMENT 'Auxiliar para que UNIQUE trate NULL como 0',
  tipo        ENUM('sector','tamano','vinculo_unab','tipo_documento','eje_diagnostico','area_asesoria','tipo_evento','nivel','medalla') NOT NULL COMMENT 'Qué lista cerrada representa',
  codigo      VARCHAR(40)  NOT NULL COMMENT 'Código estable (nunca cambia)',
  nombre      VARCHAR(100) NOT NULL COMMENT 'Etiqueta visible',
  valor       INT NULL COMMENT 'Dato numérico auxiliar (XP requerido en tipo=nivel)',
  orden       SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Orden de despliegue en listas',
  activo      TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'Disponible para nuevos registros',
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_catalogo_tenant_tipo_codigo (tenant_key, tipo, codigo),
  KEY idx_catalogo_tipo_activo_orden (tipo, activo, orden),
  CONSTRAINT fk_catalogo_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Catálogo unificado de listas cerradas (sectores, tamaños, vínculos, ejes, niveles, medallas...)';

/* --------------------------------------------------------------------------- */
CREATE TABLE empresas (
  id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id         INT UNSIGNED NOT NULL,
  nit               VARCHAR(20)  NULL COMMENT 'NIT sin dígito de verificación; NULL si se desconoce',
  razon_social      VARCHAR(200) NOT NULL COMMENT 'Nombre legal',
  nombre_comercial  VARCHAR(200) NOT NULL COMMENT 'Nombre mostrado en la UI',
  sector_id         SMALLINT UNSIGNED NOT NULL COMMENT 'FK catalogo_items (tipo=sector)',
  tamano_id         SMALLINT UNSIGNED NULL COMMENT 'FK catalogo_items (tipo=tamano)',
  municipio         VARCHAR(80)  NULL COMMENT 'Texto libre (ej. Bucaramanga)',
  email_contacto    VARCHAR(190) NULL,
  telefono          VARCHAR(25)  NULL,
  numero_empleados  SMALLINT UNSIGNED NULL COMMENT 'Dato reportado por la empresa',
  estado            ENUM('activa','inactiva','por_revisar','fusionada') NOT NULL DEFAULT 'activa' COMMENT '"Incompleta" es derivada (vw_empresa_resumen)',
  fusionada_en_id   BIGINT UNSIGNED NULL COMMENT 'Empresa sobreviviente si estado=fusionada',
  fuente_origen     VARCHAR(60)  NULL COMMENT 'Hoja/archivo del Google Sheets legado',
  vector_sync       ENUM('pendiente','sincronizado','error') NOT NULL DEFAULT 'pendiente' COMMENT 'Patrón outbox hacia Qdrant (cde_companies)',
  vector_hash       CHAR(64)     NULL COMMENT 'SHA-256 del texto embebido; si cambia hay que reindexar',
  deleted_at        DATETIME(3)  NULL COMMENT 'Soft delete',
  created_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_empresas_tenant_id  (tenant_id, id),
  UNIQUE KEY uq_empresas_tenant_nit (tenant_id, nit),
  KEY idx_empresas_sector_estado (tenant_id, sector_id, estado, deleted_at),
  KEY idx_empresas_estado        (tenant_id, estado, deleted_at),
  KEY idx_empresas_vector_sync   (tenant_id, vector_sync),
  KEY idx_empresas_fusionada_en  (tenant_id, fusionada_en_id),
  KEY idx_empresas_tamano        (tamano_id),
  FULLTEXT KEY ft_empresas_nombre (razon_social, nombre_comercial),
  CONSTRAINT fk_empresas_tenant    FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_empresas_sector    FOREIGN KEY (sector_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_empresas_tamano    FOREIGN KEY (tamano_id) REFERENCES catalogo_items (id),
  CONSTRAINT fk_empresas_fusionada FOREIGN KEY (tenant_id, fusionada_en_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT ck_empresas_fusion CHECK (estado <> 'fusionada' OR fusionada_en_id IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Empresas únicas atendidas (maestra del Expediente 360)';

/* --------------------------------------------------------------------------- */
CREATE TABLE usuarios (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  email           VARCHAR(190) NOT NULL COMMENT 'Correo institucional',
  password_hash   VARCHAR(255) NULL COMMENT 'Argon2id; NULL si solo entra por SSO UNAB',
  sso_subject     VARCHAR(190) NULL COMMENT 'ID del proveedor "Entrar con cuenta UNAB"',
  nombre_mostrar  VARCHAR(120) NOT NULL COMMENT 'Nombre del avatar (JD)',
  rol             ENUM('admin_cde','consultor','emprendedor') NOT NULL COMMENT 'RBAC; viaja en el payload del JWT',
  empresa_id      BIGINT UNSIGNED NULL COMMENT 'Solo emprendedores: empresa de la vista Mi empresa',
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
  CONSTRAINT ck_usuarios_credencial CHECK (password_hash IS NOT NULL OR sso_subject IS NOT NULL),
  CONSTRAINT ck_usuarios_emprendedor CHECK (rol <> 'emprendedor' OR empresa_id IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Cuentas de acceso (admin_cde, consultor, emprendedor)';

/* --------------------------------------------------------------------------- */
CREATE TABLE refresh_tokens (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  usuario_id  BIGINT UNSIGNED NOT NULL,
  token_hash  CHAR(64) NOT NULL COMMENT 'SHA-256 del refresh token (nunca el token en claro)',
  expira_at   DATETIME(3) NOT NULL,
  revocado_at DATETIME(3) NULL COMMENT 'Rotación o logout',
  ip          VARBINARY(16) NULL COMMENT 'INET6_ATON(ip)',
  user_agent  VARCHAR(255) NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_refresh_token_hash (token_hash),
  KEY idx_refresh_usuario_vigencia (tenant_id, usuario_id, revocado_at, expira_at),
  KEY idx_refresh_expira (expira_at),
  CONSTRAINT fk_refresh_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_refresh_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id) ON DELETE CASCADE
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Refresh tokens JWT con rotación y revocación';

/* --------------------------------------------------------------------------- */
CREATE TABLE auditoria_seguridad (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  usuario_id  BIGINT UNSIGNED NULL COMMENT 'Actor; NULL si es el sistema',
  accion      VARCHAR(60) NOT NULL COMMENT 'login_ok, login_fail, fusion_empresa, cambio_estado_plan...',
  entidad     VARCHAR(60) NULL COMMENT 'Tabla afectada',
  entidad_id  BIGINT UNSIGNED NULL COMMENT 'Registro afectado',
  detalle     JSON NULL COMMENT 'Estado antes/después',
  ip          VARBINARY(16) NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_audit_tenant_fecha   (tenant_id, created_at),
  KEY idx_audit_usuario_fecha  (tenant_id, usuario_id, created_at),
  KEY idx_audit_entidad        (tenant_id, entidad, entidad_id),
  KEY idx_audit_accion_fecha   (tenant_id, accion, created_at),
  CONSTRAINT fk_audit_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_audit_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Bitácora append-only de seguridad (no se actualiza ni se borra)';

/* ---------------------------------------------------------------------------
   3. ENTIDADES MAESTRAS (personas, alias)
   --------------------------------------------------------------------------- */

CREATE TABLE personas (
  id                    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id             INT UNSIGNED NOT NULL,
  tipo_documento_id     SMALLINT UNSIGNED NOT NULL COMMENT 'FK catalogo_items (tipo=tipo_documento)',
  numero_documento      VARCHAR(25) NOT NULL,
  nombres               VARCHAR(100) NOT NULL,
  apellidos             VARCHAR(100) NOT NULL,
  email                 VARCHAR(190) NULL,
  telefono              VARCHAR(25) NULL COMMENT 'Teléfono/WhatsApp',
  empresa_id            BIGINT UNSIGNED NULL COMMENT 'Empresa donde trabaja; NULL para docentes y estudiantes',
  es_contacto_principal TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Contacto mostrado en el Expediente 360',
  vinculo_unab_id       SMALLINT UNSIGNED NULL COMMENT 'FK catalogo_items (tipo=vinculo_unab); alimenta "Comunidad UNAB"',
  habeas_data_at        DATETIME(3) NULL COMMENT 'Aceptación de tratamiento de datos (Ley 1581)',
  deleted_at            DATETIME(3) NULL,
  contacto_empresa_key  BIGINT UNSIGNED GENERATED ALWAYS AS
                        (IF(es_contacto_principal = 1 AND deleted_at IS NULL, empresa_id, NULL)) STORED
                        COMMENT 'Auxiliar: garantiza un solo contacto principal vigente por empresa',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Personas: contactos de empresas, docentes y estudiantes UNAB';

/* --------------------------------------------------------------------------- */
CREATE TABLE empresa_alias (
  id                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id          INT UNSIGNED NOT NULL,
  empresa_id         BIGINT UNSIGNED NOT NULL COMMENT 'Empresa canónica',
  alias              VARCHAR(200) NOT NULL COMMENT 'Variante original (ej. "Panad. San Jose")',
  alias_normalizado  VARCHAR(200) NOT NULL COMMENT 'Minúsculas, sin tildes ni sufijos legales (SAS, LTDA)',
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_alias_normalizado (tenant_id, alias_normalizado),
  KEY idx_alias_empresa (tenant_id, empresa_id),
  CONSTRAINT fk_alias_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_alias_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id) ON DELETE CASCADE
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Variantes de nombre; bloquea duplicados exactos antes de consultar Qdrant';

/* ---------------------------------------------------------------------------
   4. INTERACCIONES · EXPEDIENTE 360
   --------------------------------------------------------------------------- */

CREATE TABLE proyectos_aula (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id           INT UNSIGNED NOT NULL,
  empresa_id          BIGINT UNSIGNED NOT NULL,
  docente_persona_id  BIGINT UNSIGNED NOT NULL COMMENT 'Docente responsable',
  asignatura          VARCHAR(150) NOT NULL,
  titulo              VARCHAR(200) NOT NULL,
  fecha_inicio        DATE NOT NULL COMMENT 'El semestre se deriva de esta fecha (fn_periodo)',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Proyectos de aula (docente + estudiantes) atendiendo una empresa';

CREATE TABLE proyecto_estudiantes (
  tenant_id    INT UNSIGNED NOT NULL,
  proyecto_id  BIGINT UNSIGNED NOT NULL,
  persona_id   BIGINT UNSIGNED NOT NULL COMMENT 'Estudiante participante',
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (proyecto_id, persona_id),
  KEY idx_proy_est_persona (tenant_id, persona_id),
  CONSTRAINT fk_proy_est_tenant   FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_proy_est_proyecto FOREIGN KEY (tenant_id, proyecto_id) REFERENCES proyectos_aula (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_proy_est_persona  FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Estudiantes de cada proyecto de aula (N:M)';

/* ---------------------------------------------------------------------------
   5a. MISIONES (se crea antes de citas porque citas la referencia)
   --------------------------------------------------------------------------- */
CREATE TABLE misiones (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  tipo             ENUM('pildora','quiz','meta','mentoria','reto_semanal') NOT NULL,
  eje_id           SMALLINT UNSIGNED NULL COMMENT 'Brecha que cierra (FK catalogo eje_diagnostico); la IA la usa para recomendar',
  nivel_minimo_id  SMALLINT UNSIGNED NULL COMMENT 'Nivel que la desbloquea (FK catalogo nivel); "Bloqueada" se deriva',
  titulo           VARCHAR(150) NOT NULL,
  pasos            JSON NOT NULL COMMENT 'Arreglo de pasos/contenido; lo renderiza <cde-sdui-renderer>',
  xp_recompensa    SMALLINT UNSIGNED NOT NULL,
  duracion_min     SMALLINT UNSIGNED NULL,
  vigente_hasta    DATETIME(3) NULL COMMENT 'Solo retos semanales ("termina en 2 d 14 h")',
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
  CONSTRAINT ck_misiones_xp CHECK (xp_recompensa > 0),
  CONSTRAINT ck_misiones_pasos CHECK (JSON_TYPE(pasos) = 'ARRAY')
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Misiones de la Academia (píldoras, quizzes, metas, mentorías, retos)';

/* --------------------------------------------------------------------------- */
CREATE TABLE citas_asesoria (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id     INT UNSIGNED NOT NULL,
  empresa_id    BIGINT UNSIGNED NOT NULL,
  consultor_id  BIGINT UNSIGNED NOT NULL COMMENT 'Usuario asesor',
  area_id       SMALLINT UNSIGNED NOT NULL COMMENT 'FK catalogo_items (tipo=area_asesoria): Costos, Marca...',
  estado        ENUM('pendiente','confirmada','realizada','cancelada') NOT NULL DEFAULT 'pendiente',
  inicio_at     DATETIME(3) NOT NULL,
  fin_at        DATETIME(3) NOT NULL,
  mision_id     BIGINT UNSIGNED NULL COMMENT 'Misión asociada (+150 XP)',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Citas de asesoría (agenda semanal)';

/* --------------------------------------------------------------------------- */
CREATE TABLE eventos (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id    INT UNSIGNED NOT NULL,
  tipo_id      SMALLINT UNSIGNED NOT NULL COMMENT 'FK catalogo_items (tipo=tipo_evento)',
  titulo       VARCHAR(200) NOT NULL,
  estado       ENUM('borrador','confirmado','realizado','cancelado') NOT NULL DEFAULT 'borrador',
  inicio_at    DATETIME(3) NOT NULL,
  fin_at       DATETIME(3) NOT NULL,
  lugar        VARCHAR(200) NULL COMMENT 'Sede o enlace virtual',
  xp_checkin   SMALLINT UNSIGNED NOT NULL DEFAULT 50 COMMENT 'XP otorgados por check-in QR',
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_eventos_tenant_id (tenant_id, id),
  KEY idx_eventos_estado_inicio (tenant_id, estado, inicio_at),
  KEY idx_eventos_tipo          (tipo_id),
  CONSTRAINT fk_eventos_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_eventos_tipo   FOREIGN KEY (tipo_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_eventos_horario CHECK (fin_at > inicio_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Eventos y capacitaciones (talleres, ferias)';

CREATE TABLE evento_convocatorias (
  tenant_id   INT UNSIGNED NOT NULL,
  evento_id   BIGINT UNSIGNED NOT NULL,
  empresa_id  BIGINT UNSIGNED NOT NULL COMMENT 'Empresa convocada (paso "Convocados" del embudo)',
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (evento_id, empresa_id),
  KEY idx_convoc_empresa (tenant_id, empresa_id),
  CONSTRAINT fk_convoc_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_convoc_evento  FOREIGN KEY (tenant_id, evento_id) REFERENCES eventos (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_convoc_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Empresas convocadas a un evento (segmentación con IA)';

CREATE TABLE evento_inscripciones (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  evento_id       BIGINT UNSIGNED NOT NULL,
  empresa_id      BIGINT UNSIGNED NOT NULL,
  persona_id      BIGINT UNSIGNED NOT NULL COMMENT 'Asistente inscrito',
  checkin_at      DATETIME(3) NULL COMMENT 'Con valor = asistió; "No asistió" se deriva',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Inscripciones y asistencia (check-in QR) por evento';

/* --------------------------------------------------------------------------- */
CREATE TABLE autodiagnosticos (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  empresa_id       BIGINT UNSIGNED NOT NULL,
  tipo             ENUM('inicial','seguimiento') NOT NULL COMMENT 'Define las series Inicial/Actual del radar',
  aplicado_por_id  BIGINT UNSIGNED NULL COMMENT 'Consultor que lo aplicó',
  aplicado_at      DATETIME(3) NOT NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_autodiag_tenant_id (tenant_id, id),
  KEY idx_autodiag_empresa_tipo_fecha (tenant_id, empresa_id, tipo, aplicado_at),
  KEY idx_autodiag_aplicador (tenant_id, aplicado_por_id),
  CONSTRAINT fk_autodiag_tenant   FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_autodiag_empresa  FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_autodiag_aplicador FOREIGN KEY (tenant_id, aplicado_por_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Autodiagnósticos de madurez empresarial';

CREATE TABLE autodiagnostico_respuestas (
  tenant_id           INT UNSIGNED NOT NULL,
  autodiagnostico_id  BIGINT UNSIGNED NOT NULL,
  eje_id              SMALLINT UNSIGNED NOT NULL COMMENT 'Uno de los 6 ejes (FK catalogo eje_diagnostico)',
  puntaje             TINYINT UNSIGNED NOT NULL COMMENT '0-100',
  brecha              VARCHAR(255) NULL COMMENT 'Texto de la brecha detectada',
  created_at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (autodiagnostico_id, eje_id),
  KEY idx_diag_resp_eje_puntaje (tenant_id, eje_id, puntaje),
  CONSTRAINT fk_diag_resp_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_diag_resp_diag   FOREIGN KEY (tenant_id, autodiagnostico_id) REFERENCES autodiagnosticos (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT fk_diag_resp_eje    FOREIGN KEY (eje_id) REFERENCES catalogo_items (id),
  CONSTRAINT ck_diag_resp_puntaje CHECK (puntaje <= 100)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Puntaje por eje de cada autodiagnóstico (alimenta el radar de capacidades)';

/* --------------------------------------------------------------------------- */
CREATE TABLE planes_accion (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id            INT UNSIGNED NOT NULL,
  empresa_id           BIGINT UNSIGNED NOT NULL,
  eje_id               SMALLINT UNSIGNED NULL COMMENT 'Brecha que ataca',
  autodiagnostico_id   BIGINT UNSIGNED NULL COMMENT 'Diagnóstico de origen',
  titulo               VARCHAR(200) NOT NULL COMMENT 'Ej. "Lanzar tienda online"',
  estado               ENUM('pendiente','en_ejecucion','en_validacion_cde','completado_con_impacto')
                       NOT NULL DEFAULT 'pendiente' COMMENT 'Columna del Kanban; "Vencido" es derivado',
  orden_kanban         INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Posición dentro de la columna',
  progreso             TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '0-100',
  responsable_id       BIGINT UNSIGNED NOT NULL COMMENT 'Consultor responsable',
  fecha_limite         DATE NOT NULL COMMENT 'Vencido si pasó y el estado no es completado',
  firmado_at           DATETIME(3) NULL COMMENT 'Firma del plan de acción',
  impacto_descripcion  VARCHAR(200) NULL COMMENT 'Ej. "+18% ventas"; se llena al validar',
  impacto_validado_at  DATETIME(3) NULL COMMENT 'Validación CDE',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Planes de acción (tablero Kanban de intervenciones)';

/* ---------------------------------------------------------------------------
   5b. GAMIFICACIÓN
   --------------------------------------------------------------------------- */

CREATE TABLE empresa_misiones (
  id                  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id           INT UNSIGNED NOT NULL,
  empresa_id          BIGINT UNSIGNED NOT NULL,
  mision_id           BIGINT UNSIGNED NOT NULL,
  estado              ENUM('en_progreso','completada') NOT NULL DEFAULT 'en_progreso' COMMENT '"Disponible" = ausencia de fila',
  pasos_completados   TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Ej. "2 de 3 pasos"',
  recomendada_por_ia  TINYINT(1) NOT NULL DEFAULT 0,
  completada_at       DATETIME(3) NULL,
  xp_reclamado_at     DATETIME(3) NULL COMMENT 'Evita reclamar XP dos veces',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Avance de cada empresa en las misiones';

CREATE TABLE xp_movimientos (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  empresa_id  BIGINT UNSIGNED NOT NULL COMMENT 'Empresa que recibe el XP',
  persona_id  BIGINT UNSIGNED NULL COMMENT 'Persona que lo ganó (ej. Laura M. +50 XP)',
  origen      ENUM('mision','checkin_evento','plan_completado','ajuste') NOT NULL,
  origen_id   BIGINT UNSIGNED NULL COMMENT 'ID del registro origen (referencia polimórfica)',
  puntos      INT NOT NULL COMMENT 'XP; libro mayor inmutable (ver triggers)',
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'Momento en que ocurrió; alimenta racha y XP semanal',
  PRIMARY KEY (id),
  UNIQUE KEY uq_xp_origen (empresa_id, origen, origen_id),
  KEY idx_xp_empresa_fecha (tenant_id, empresa_id, created_at, puntos),
  KEY idx_xp_persona       (tenant_id, persona_id),
  CONSTRAINT fk_xp_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_xp_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_xp_persona FOREIGN KEY (tenant_id, persona_id) REFERENCES personas (tenant_id, id),
  CONSTRAINT ck_xp_puntos CHECK (puntos <> 0)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Libro mayor de XP (append-only). XP total = SUM(puntos)';

CREATE TABLE empresa_medallas (
  tenant_id    INT UNSIGNED NOT NULL,
  empresa_id   BIGINT UNSIGNED NOT NULL,
  medalla_id   SMALLINT UNSIGNED NOT NULL COMMENT 'FK catalogo_items (tipo=medalla)',
  obtenida_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (empresa_id, medalla_id),
  KEY idx_emp_medalla (tenant_id, medalla_id),
  CONSTRAINT fk_emp_medalla_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_emp_medalla_empresa FOREIGN KEY (tenant_id, empresa_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_emp_medalla_medalla FOREIGN KEY (medalla_id) REFERENCES catalogo_items (id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Medallas obtenidas por cada empresa';

/* ---------------------------------------------------------------------------
   6. AUTOMATIZACIONES
   --------------------------------------------------------------------------- */
CREATE TABLE reglas_automatizacion (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  nombre           VARCHAR(150) NOT NULL COMMENT 'Ej. "Recordatorio de cita"',
  estado           ENUM('activo','pausado','borrador') NOT NULL DEFAULT 'borrador',
  definicion       JSON NOT NULL COMMENT 'Nodos {cuando, si, entonces}; validado con Pydantic antes de guardar',
  creada_con_ia    TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Originada en el asistente de reglas',
  n8n_workflow_id  VARCHAR(80) NULL COMMENT 'Flujo espejo en N8N (N8N conserva el log de ejecuciones)',
  creada_por_id    BIGINT UNSIGNED NOT NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_reglas_nombre (tenant_id, nombre),
  KEY idx_reglas_estado (tenant_id, estado),
  KEY idx_reglas_autor  (tenant_id, creada_por_id),
  CONSTRAINT fk_reglas_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_reglas_autor  FOREIGN KEY (tenant_id, creada_por_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT ck_reglas_definicion CHECK (JSON_TYPE(definicion) = 'OBJECT')
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Reglas CUANDO → SI → ENTONCES (lienzo de automatizaciones)';

/* ---------------------------------------------------------------------------
   7. INGESTA Y DEDUPLICACIÓN
   --------------------------------------------------------------------------- */
CREATE TABLE migracion_lotes (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id              INT UNSIGNED NOT NULL,
  usuario_id             BIGINT UNSIGNED NOT NULL COMMENT 'Quien ejecuta el asistente de configuración',
  estado                 ENUM('subir','revisar','confirmado') NOT NULL DEFAULT 'subir' COMMENT 'Paso del wizard',
  total_atenciones       INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Filas leídas (569)',
  total_empresas_unicas  INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Empresas tras deduplicar (497)',
  confirmado_at          DATETIME(3) NULL,
  created_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_lotes_tenant_id (tenant_id, id),
  KEY idx_lotes_estado_fecha (tenant_id, estado, created_at),
  KEY idx_lotes_usuario      (tenant_id, usuario_id),
  CONSTRAINT fk_lotes_tenant  FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_lotes_usuario FOREIGN KEY (tenant_id, usuario_id) REFERENCES usuarios (tenant_id, id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Lotes de migración desde Excel / Google Sheets';

CREATE TABLE duplicados_candidatos (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id        INT UNSIGNED NOT NULL,
  lote_id          BIGINT UNSIGNED NULL COMMENT 'NULL si lo detectó el guardián en vivo',
  empresa_a_id     BIGINT UNSIGNED NOT NULL COMMENT 'Menor id del par (a < b)',
  empresa_b_id     BIGINT UNSIGNED NOT NULL COMMENT 'Mayor id del par',
  score            DECIMAL(5,4) NOT NULL COMMENT 'Similitud coseno devuelta por Qdrant (0-1)',
  estado           ENUM('por_revisar','fusionado','descartado') NOT NULL DEFAULT 'por_revisar',
  snapshot_previo  JSON NULL COMMENT 'Estado previo y FKs reasignadas; permite "Deshacer"',
  resuelto_por_id  BIGINT UNSIGNED NULL,
  resuelto_at      DATETIME(3) NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_dup_par (tenant_id, empresa_a_id, empresa_b_id),
  KEY idx_dup_cola   (tenant_id, estado, score DESC),
  KEY idx_dup_lote   (tenant_id, lote_id),
  KEY idx_dup_b      (tenant_id, empresa_b_id),
  KEY idx_dup_resolutor (tenant_id, resuelto_por_id),
  CONSTRAINT fk_dup_tenant   FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT fk_dup_lote     FOREIGN KEY (tenant_id, lote_id) REFERENCES migracion_lotes (tenant_id, id),
  CONSTRAINT fk_dup_empresa_a FOREIGN KEY (tenant_id, empresa_a_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_dup_empresa_b FOREIGN KEY (tenant_id, empresa_b_id) REFERENCES empresas (tenant_id, id),
  CONSTRAINT fk_dup_resolutor FOREIGN KEY (tenant_id, resuelto_por_id) REFERENCES usuarios (tenant_id, id),
  CONSTRAINT ck_dup_orden CHECK (empresa_a_id < empresa_b_id),
  CONSTRAINT ck_dup_score CHECK (score >= 0 AND score <= 1),
  CONSTRAINT ck_dup_resolucion CHECK ((estado = 'por_revisar' AND resuelto_at IS NULL)
                                   OR (estado <> 'por_revisar' AND resuelto_at IS NOT NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Pares de empresas sospechosas de duplicado (cola de revisión)';

/* ---------------------------------------------------------------------------
   8. IA Y SERVER-DRIVEN UI
   --------------------------------------------------------------------------- */
CREATE TABLE ia_consultas (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id       INT UNSIGNED NOT NULL,
  usuario_id      BIGINT UNSIGNED NOT NULL,
  empresa_id      BIGINT UNSIGNED NULL COMMENT 'Para síntesis del Expediente 360',
  funcion         ENUM('pregunta_datos','hallazgos','segmentacion','regla','sintesis','mision') NOT NULL,
  modelo          VARCHAR(60) NOT NULL COMMENT 'Modelo Gemini usado (Flash / Flash Lite)',
  prompt          TEXT NOT NULL,
  respuesta       JSON NULL COMMENT 'Salida validada con Pydantic; hallazgos y síntesis se cachean aquí',
  valida          TINYINT(1) NOT NULL DEFAULT 0 COMMENT '1 = pasó la validación estricta',
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
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Bitácora de llamadas a IA: costo por tenant, caché y trazabilidad';

CREATE TABLE sdui_esquemas (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   INT UNSIGNED NOT NULL,
  ruta        VARCHAR(120) NOT NULL COMMENT 'Vista (ej. /cde/dashboard)',
  rol         ENUM('admin_cde','consultor','emprendedor') NULL COMMENT 'NULL = aplica a todos los roles',
  rol_key     VARCHAR(20) GENERATED ALWAYS AS (IFNULL(rol, '*')) STORED COMMENT 'Auxiliar para UNIQUE con rol NULL',
  version     SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  esquema     JSON NOT NULL COMMENT 'Árbol de componentes <cde-*> que renderiza <cde-sdui-renderer>',
  activo      TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Versión vigente',
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uq_sdui_version (tenant_id, ruta, rol_key, version),
  KEY idx_sdui_vigente (tenant_id, ruta, activo),
  CONSTRAINT fk_sdui_tenant FOREIGN KEY (tenant_id) REFERENCES tenants (id),
  CONSTRAINT ck_sdui_esquema CHECK (JSON_TYPE(esquema) = 'OBJECT')
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='Esquemas de UI dictados por el backend (Server-Driven UI)';

SET FOREIGN_KEY_CHECKS = 1;

/* ---------------------------------------------------------------------------
   9. FUNCIÓN Y TRIGGERS
   --------------------------------------------------------------------------- */
DELIMITER $$

CREATE FUNCTION fn_periodo(d DATETIME) RETURNS CHAR(6)
  DETERMINISTIC NO SQL
  COMMENT 'Periodo académico: enero-junio = -1, julio-diciembre = -2 (ej. 2026-2)'
BEGIN
  RETURN CONCAT(YEAR(d), '-', IF(MONTH(d) <= 6, 1, 2));
END$$

/* Marca la empresa como pendiente de reindexar en Qdrant si cambia su texto semántico */
CREATE TRIGGER trg_empresas_bu_vector
BEFORE UPDATE ON empresas FOR EACH ROW
BEGIN
  IF NOT (NEW.razon_social <=> OLD.razon_social
      AND NEW.nombre_comercial <=> OLD.nombre_comercial
      AND NEW.sector_id <=> OLD.sector_id
      AND NEW.municipio <=> OLD.municipio)
     AND (NEW.vector_sync <=> OLD.vector_sync) THEN
    SET NEW.vector_sync = 'pendiente';
  END IF;
END$$

/* Libro mayor de XP inmutable: las correcciones se hacen con un movimiento 'ajuste' */
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
   10. VISTAS DERIVADAS (nada derivado se almacena → 3FN)
   --------------------------------------------------------------------------- */

/* % de ficha, estado "Incompleta" y marca "Comunidad UNAB" */
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

/* Línea de tiempo cronológica del Expediente 360 (<cde-timeline-360>) */
CREATE OR REPLACE VIEW vw_expediente_360 AS
SELECT p.tenant_id, p.empresa_id, 'proyecto' AS tipo,
       CAST(p.fecha_inicio AS DATETIME(3)) AS fecha,
       p.titulo AS titulo, p.asignatura AS detalle, p.id AS ref_id
FROM proyectos_aula p
UNION ALL
SELECT c.tenant_id, c.empresa_id, 'cita', c.inicio_at,
       CONCAT('Asesoría · ', a.nombre), CAST(c.estado AS CHAR), c.id
FROM citas_asesoria c
JOIN catalogo_items a ON a.id = c.area_id
UNION ALL
SELECT i.tenant_id, i.empresa_id, 'evento', COALESCE(i.checkin_at, ev.inicio_at),
       ev.titulo, IF(i.checkin_at IS NULL, 'Inscrito', 'Asistió'), i.id
FROM evento_inscripciones i
JOIN eventos ev ON ev.tenant_id = i.tenant_id AND ev.id = i.evento_id
UNION ALL
SELECT d.tenant_id, d.empresa_id, 'diagnostico', d.aplicado_at,
       CONCAT('Diagnóstico ', d.tipo),
       (SELECT GROUP_CONCAT(r.brecha SEPARATOR '; ')
          FROM autodiagnostico_respuestas r
         WHERE r.autodiagnostico_id = d.id AND r.brecha IS NOT NULL),
       d.id
FROM autodiagnosticos d
UNION ALL
SELECT pa.tenant_id, pa.empresa_id, 'plan', pa.firmado_at,
       'Plan de acción firmado', pa.titulo, pa.id
FROM planes_accion pa
WHERE pa.firmado_at IS NOT NULL
UNION ALL
SELECT pa.tenant_id, pa.empresa_id, 'impacto', pa.impacto_validado_at,
       'Validación CDE', pa.impacto_descripcion, pa.id
FROM planes_accion pa
WHERE pa.impacto_validado_at IS NOT NULL;

/* XP total, nivel, siguiente umbral, XP de la semana, días activos y medallas */
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

/* Embudo de conversión: convocados → inscritos → asistentes */
CREATE OR REPLACE VIEW vw_evento_embudo AS
SELECT t.*,
       ROUND(100 * t.asistentes / NULLIF(t.convocados, 0), 1) AS pct_asistencia_sobre_convocados
FROM (
  SELECT ev.tenant_id, ev.id AS evento_id, ev.titulo, ev.estado,
         (SELECT COUNT(*) FROM evento_convocatorias c WHERE c.evento_id = ev.id) AS convocados,
         (SELECT COUNT(*) FROM evento_inscripciones i WHERE i.evento_id = ev.id) AS inscritos,
         (SELECT COUNT(*) FROM evento_inscripciones i
           WHERE i.evento_id = ev.id AND i.checkin_at IS NOT NULL) AS asistentes
  FROM eventos ev
) t;

/* Empresas atendidas, atenciones y % por sector y periodo (dashboard territorial) */
CREATE OR REPLACE VIEW vw_dashboard_sector AS
SELECT a.tenant_id, a.periodo, s.id AS sector_id, s.nombre AS sector,
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
JOIN catalogo_items s ON s.id = e.sector_id
GROUP BY a.tenant_id, a.periodo, s.id, s.nombre;

/* Planes con bandera de vencido (alerta "12 empresas con planes vencidos") */
CREATE OR REPLACE VIEW vw_planes_accion_estado AS
SELECT p.tenant_id, p.id AS plan_id, p.empresa_id, e.nombre_comercial AS empresa,
       p.titulo, p.estado, p.progreso, p.responsable_id, p.fecha_limite,
       (p.estado <> 'completado_con_impacto' AND p.fecha_limite < CURDATE()) AS vencido
FROM planes_accion p
JOIN empresas e ON e.tenant_id = p.tenant_id AND e.id = p.empresa_id;

/* ---------------------------------------------------------------------------
   11. SEED (AJUSTAR los catálogos al Excel oficial del CDE antes de producción)
   --------------------------------------------------------------------------- */
INSERT INTO tenants (slug, nombre, plan) VALUES ('unab-cde', 'Centro de Desarrollo Empresarial UNAB', 'enterprise');

/* Catálogos GLOBALES (tenant_id NULL) */
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

 (NULL,'medalla','primer_plan','Primer plan',NULL,1),
 (NULL,'medalla','constante','Constante',NULL,2),
 (NULL,'medalla','despegue','Despegue',NULL,3),
 (NULL,'medalla','lider','Líder',NULL,4),
 (NULL,'medalla','referente','Referente',NULL,5);

/* Misiones demo del tenant UNAB (coinciden con los wireframes de la Academia) */
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

/* ---------------------------------------------------------------------------
   12. NOTAS DE AFINAMIENTO (my.cnf sugerido para el VPS)
   ---------------------------------------------------------------------------
   [mysqld]
   innodb_buffer_pool_size        = 50% de la RAM del VPS
   innodb_flush_log_at_trx_commit = 1          # durabilidad; usar 2 solo en demo
   innodb_ft_min_token_size       = 2          # FULLTEXT útil con nombres cortos
   max_connections                = 100
   sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO'
   default_time_zone              = '+00:00'

   BUENAS PRÁCTICAS DE USO
   - Toda consulta de la API debe filtrar por tenant_id (TenantContext en el repositorio).
   - Crear el par de duplicados SIEMPRE ordenado: (MIN(id), MAX(id)).
   - Rotar auditoria_seguridad con respaldo externo (es append-only); particionar solo si
     se elimina su FK a usuarios (MySQL no permite FK en tablas particionadas).
   - Reindexar en Qdrant las empresas con vector_sync = 'pendiente' (worker outbox).
   - Usuario de aplicación con privilegios mínimos (SELECT/INSERT/UPDATE/DELETE), sin DDL.
   ------------------------------------------------------------------------- */