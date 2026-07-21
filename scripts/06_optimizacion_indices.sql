-- ==============================================================================
-- SCRIPT 06
-- Versión: 2.0 | Senior DBA & Data Engineering | SQL Server 2019+
-- ==============================================================================
USE Streaming_Retention_Insights_v2;
GO

-- ==============================================================================
-- 1. ÍNDICE PARA SUSCRIPCIONES (FECHAS Y CLIENTE)
-- Utilizado en: Retención por cohorte, churn mensual
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Suscripciones_Fechas_Cliente' AND object_id = OBJECT_ID('core.Suscripciones'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Suscripciones_Fechas_Cliente
    ON core.Suscripciones (fecha_inicio, fecha_fin)
    INCLUDE (id_cliente, id_plan, estado);
END
GO

-- ==============================================================================
-- 2. ÍNDICE PARA ACTIVIDAD DE USUARIO (FECHA RECIENTE)
-- Utilizado en: Clientes en riesgo (baja actividad)
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Actividad_Usuario_Fecha_Cliente' AND object_id = OBJECT_ID('analytics.Actividad_Usuario'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Actividad_Usuario_Fecha_Cliente
    ON analytics.Actividad_Usuario (fecha_actividad)
    INCLUDE (id_cliente, minutos_escuchados);
END
GO

-- ==============================================================================
-- 3. ÍNDICE PARA PAGOS (ESTADO Y FECHA)
-- Utilizado en: Pagos fallidos recientes (clientes en riesgo)
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Pagos_Estado_Fecha' AND object_id = OBJECT_ID('core.Pagos'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Pagos_Estado_Fecha
    ON core.Pagos (estado_pago, fecha_pago)
    INCLUDE (id_suscripcion, monto_bruto);
END
GO

-- ==============================================================================
-- 4. ÍNDICE PARA SUSCRIPCIONES ACTIVAS (CLIENTE Y FECHA DESCENDENTE)
-- Utilizado en: Obtener suscripción activa más reciente por cliente (Optimiza ROW_NUMBER)
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Suscripciones_Estado_Cliente_Fecha' AND object_id = OBJECT_ID('core.Suscripciones'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Suscripciones_Estado_Cliente_Fecha
    ON core.Suscripciones (id_cliente, fecha_inicio DESC)
    INCLUDE (estado);
END
GO

-- ==============================================================================
-- 5. ÍNDICE PARA CLIENTES (EMAIL)
-- Utilizado en: Búsquedas puntuales y cruces directos
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Clientes_Email' AND object_id = OBJECT_ID('core.Clientes'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Clientes_Email
    ON core.Clientes (email);
END
GO

-- ==============================================================================
-- 6. ÍNDICE PARA ACTIVIDAD POR CLIENTE Y FECHA
-- Utilizado en: Soporte para análisis de tendencias
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_Actividad_Usuario_Cliente_Fecha' AND object_id = OBJECT_ID('analytics.Actividad_Usuario'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_Actividad_Usuario_Cliente_Fecha
    ON analytics.Actividad_Usuario (id_cliente, fecha_actividad)
    INCLUDE (minutos_escuchados, canciones_reproducidas);
END
GO

-- ==============================================================================
-- VERIFICACIÓN DE ÍNDICES CREADOS
-- ==============================================================================
SELECT 
    i.name AS IndexName,
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS TableName,
    i.type_desc,
    i.is_unique,
    i.is_primary_key
FROM sys.indexes i
WHERE i.object_id IN (
    OBJECT_ID('core.Suscripciones'), 
    OBJECT_ID('analytics.Actividad_Usuario'), 
    OBJECT_ID('core.Pagos'), 
    OBJECT_ID('core.Clientes')
)
  AND i.name IS NOT NULL
  AND i.type_desc != 'HEAP'
ORDER BY TableName, IndexName;
GO

-- ==============================================================================
-- (OPCIONAL) Recomendación de monitoreo de uso de índices
-- Ejecutar después de unas cuantas ejecuciones de consultas para ver qué índices se usan realmente
-- ==============================================================================
/*
SELECT 
    OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id) AS TableName,
    i.name AS IndexName,
    s.user_seeks, s.user_scans, s.user_lookups, s.user_updates
FROM sys.dm_db_index_usage_stats s
JOIN sys.indexes i ON s.object_id = i.object_id AND s.index_id = i.index_id
WHERE s.database_id = DB_ID('Streaming_Retention_Insights_v2')
ORDER BY TableName, IndexName;
GO
*/