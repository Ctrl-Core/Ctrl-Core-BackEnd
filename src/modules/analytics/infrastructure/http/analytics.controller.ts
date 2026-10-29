import { Request, Response } from 'express';
import { dbPool } from '../../../../shared/database/connection';

export const getDashboardBI = async (req: Request, res: Response) => {
  const tenantId = req.tenantId;

  try {
    // 1. Métricas de cabecera generales
    const [empresasCount]: any = await dbPool.execute(
      'SELECT COUNT(*) as total FROM empresas WHERE tenant_id = ? AND deleted_at IS NULL',
      [tenantId]
    );

    // 2. Distribución por Sectores (usando la vista o catalogo)
    const [sectoresRows]: any = await dbPool.execute(`
      SELECT c.nombre AS sector, COUNT(e.id) AS total
      FROM empresas e
      JOIN catalogo_items c ON c.id = e.sector_id
      WHERE e.tenant_id = ? AND e.deleted_at IS NULL
      GROUP BY c.id, c.nombre
      ORDER BY total DESC
      LIMIT 6
    `, [tenantId]);

    // 3. Distribución Geográfica (Top Municipios de Santander)
    const [municipiosRows]: any = await dbPool.execute(`
      SELECT IFNULL(municipio, 'No especificado') AS municipio, COUNT(id) AS total
      FROM empresas
      WHERE tenant_id = ? AND deleted_at IS NULL
      GROUP BY municipio
      ORDER BY total DESC
      LIMIT 5
    `, [tenantId]);

    // Formateado directo para Chart.js
    res.json({
      success: true,
      tenant_id: tenantId,
      data: {
        kpis: {
          total_empresas: empresasCount[0]?.total || 0,
          atenciones_acumuladas: 1196,
          comunidad_unab_pct: 35.1
        },
        grafico_sectores: {
          labels: sectoresRows.map((r: any) => r.sector),
          datasets: [{
            label: 'Empresas por Sector',
            data: sectoresRows.map((r: any) => r.total),
            backgroundColor: ['#6B21A8', '#9333EA', '#A855F7', '#C084FC', '#E9D5FF', '#F3E8FF']
          }]
        },
        grafico_municipios: {
          labels: municipiosRows.map((r: any) => r.municipio),
          datasets: [{
            label: 'Distribución Territorial',
            data: municipiosRows.map((r: any) => r.total),
            backgroundColor: '#0D9488'
          }]
        },
        plan_accion_2026: [
          { programa: "Programa de Fortalecimiento/Incubación", meta: 10, avance: 15, estado: "EN_META" },
          { programa: "Programa de Consultoría Empresarial Junior", meta: 40, avance: 71, estado: "EN_META" },
          { programa: "Fomento Mentalidad Emprendedora", meta: 380, avance: 202, estado: "EN_PROGRESO" },
          { programa: "Conector Servicios Empresariales UNAB", meta: 3, avance: 0, estado: "REZAGADO" }
        ]
      }
    });
    
  } catch (error) {
    console.error('[AnalyticsController] Error:', error);
    res.status(500).json({ success: false, message: 'Error al generar analítica BI' });
  }
};