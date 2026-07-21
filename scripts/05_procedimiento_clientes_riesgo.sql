-- ==============================================================================
-- SCRIPT 05 | PREVENCIÓN Y AUTOMATIZACIÓN (STORED PROCEDURE)
-- INCLUYE: Creación de tabla histórica y Stored Procedure parametrizado
-- Versión: 2.0 | Analytics & Data Engineering | SQL Server 2019+
-- ==============================================================================
USE Streaming_Retention_Insights_v2;
GO

-- ==============================================================================
-- 1. CREAR TABLA DE HISTORIAL (Esquema 'core')
-- ==============================================================================
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ReporteRiesgoHistorico' AND schema_id = SCHEMA_ID('core'))
BEGIN
    CREATE TABLE core.ReporteRiesgoHistorico (
        id_reporte BIGINT IDENTITY(1,1) PRIMARY KEY,
        fecha_ejecucion DATETIME NOT NULL DEFAULT GETDATE(),
        fecha_corte_analisis DATE NOT NULL, -- Para saber de qué fecha son los datos
        id_cliente INT NOT NULL,
        email VARCHAR(100),
        pais VARCHAR(50),
        edad INT,
        nombre_plan VARCHAR(50),
        fecha_inicio DATE,
        fecha_fin DATE NULL,
        dias_activo INT,
        promedio_minutos DECIMAL(10,2),
        pagos_fallidos INT,
        puntaje_riesgo INT,
        nivel_riesgo VARCHAR(50),
        recomendacion VARCHAR(500),
        CONSTRAINT FK_Riesgo_Cliente FOREIGN KEY (id_cliente) REFERENCES core.Clientes(id_cliente)
    );
END
GO

-- ==============================================================================
-- 2. CREACIÓN DEL PROCEDIMIENTO ALMACENADO
-- ==============================================================================
CREATE OR ALTER PROCEDURE sp_reporte_clientes_riesgo
    -- Filtros de Portafolio
    @filtro_id_pais TINYINT = NULL,
    @filtro_id_plan TINYINT = NULL,
    @FechaCorte DATE = '2026-06-18',    -- Fecha real de los datos para evitar desfases
    
    -- Parámetros de Negocio Ajustables
    @MinutosBajaActividad INT = 30,
    @DiasInactividad INT = 7,
    @DiasPagoFallido INT = 30,
    @DiasProximoVencimiento INT = 15,
    @MesesAntiguedadRiesgo INT = 6,
    
    -- Controles de Ejecución
    @GuardarHistorico BIT = 1,          -- 1 = guarda en tabla, 0 = solo muestra
    @MostrarSoloRiesgo BIT = 1          -- 1 = solo clientes con riesgo (>0), 0 = todos
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        
        -- CTE principal con reglas de negocio
        ;WITH 
        ActividadReciente AS (
            SELECT 
                id_cliente,
                -- Multiplicamos por 1.0 para forzar el tipo decimal en SQL Server
                AVG(minutos_escuchados * 1.0) AS promedio_minutos_diarios,
                COUNT(DISTINCT fecha_actividad) AS dias_con_actividad
            FROM analytics.Actividad_Usuario
            WHERE fecha_actividad >= DATEADD(day, -@DiasInactividad, @FechaCorte)
            GROUP BY id_cliente
        ),
        PagosFallidos AS (
            SELECT 
                s.id_cliente,
                COUNT(p.id_pago) AS total_fallidos_recientes
            FROM core.Pagos p
            INNER JOIN core.Suscripciones s ON p.id_suscripcion = s.id_suscripcion
            WHERE p.estado_pago = 'fallido'
              AND p.fecha_pago >= DATEADD(day, -@DiasPagoFallido, @FechaCorte)
            GROUP BY s.id_cliente
        ),
        SuscripcionActiva AS (
            SELECT 
                id_cliente,
                id_suscripcion,
                id_plan,
                fecha_inicio,
                fecha_fin,
                estado,
                ROW_NUMBER() OVER (PARTITION BY id_cliente ORDER BY fecha_inicio DESC) AS rn
            FROM core.Suscripciones
            WHERE estado = 'activa' 
              AND (fecha_fin IS NULL OR fecha_fin >= @FechaCorte)
        ),
        SuscripcionesActuales AS (
            SELECT * FROM SuscripcionActiva WHERE rn = 1
        ),
        PlanesInfo AS (
            SELECT id_plan, nombre_plan 
            FROM core.Planes
        ),
        RiesgoCalculado AS (
            SELECT 
                c.id_cliente,
                c.email,
                pm.nombre_pais AS pais,
                c.edad,
                sa.id_plan,
                p.nombre_plan,
                sa.fecha_inicio,
                sa.fecha_fin,
                DATEDIFF(day, sa.fecha_inicio, @FechaCorte) AS dias_activo,
                ISNULL(ar.promedio_minutos_diarios, 0) AS promedio_minutos,
                ISNULL(ar.dias_con_actividad, 0) AS dias_activos_periodo,
                ISNULL(pf.total_fallidos_recientes, 0) AS pagos_fallidos,
                
                -- Señales de Riesgo
                CASE WHEN ISNULL(ar.promedio_minutos_diarios, 0) < @MinutosBajaActividad AND ar.dias_con_actividad > 0 THEN 1 ELSE 0 END AS riesgo_baja_actividad,
                CASE WHEN ISNULL(pf.total_fallidos_recientes, 0) > 0 THEN 1 ELSE 0 END AS riesgo_pagos_fallidos,
                CASE WHEN sa.fecha_fin IS NOT NULL 
                     AND p.nombre_plan NOT LIKE '%Anual%'
                     AND DATEDIFF(day, @FechaCorte, sa.fecha_fin) BETWEEN 0 AND @DiasProximoVencimiento THEN 1 ELSE 0 END AS riesgo_proximo_vencimiento,
                CASE WHEN DATEDIFF(day, sa.fecha_inicio, @FechaCorte) > (@MesesAntiguedadRiesgo * 30) 
                     AND ISNULL(ar.promedio_minutos_diarios, 0) < (@MinutosBajaActividad * 0.5) THEN 1 ELSE 0 END AS riesgo_antiguo_inactivo
            FROM core.Clientes c
            INNER JOIN SuscripcionesActuales sa ON c.id_cliente = sa.id_cliente
            INNER JOIN PlanesInfo p ON sa.id_plan = p.id_plan
            LEFT JOIN core.Paises_Monedas pm ON c.id_pais = pm.id_pais
            LEFT JOIN ActividadReciente ar ON c.id_cliente = ar.id_cliente
            LEFT JOIN PagosFallidos pf ON c.id_cliente = pf.id_cliente
            -- Aplicación de parámetros globales (filtros)
            WHERE (@filtro_id_pais IS NULL OR c.id_pais = @filtro_id_pais)
              AND (@filtro_id_plan IS NULL OR sa.id_plan = @filtro_id_plan)
        ),
        RiesgoFinal AS (
            SELECT 
                id_cliente,
                email,
                pais,
                edad,
                nombre_plan,
                fecha_inicio,
                fecha_fin,
                dias_activo,
                CAST(promedio_minutos AS DECIMAL(10,2)) AS promedio_minutos,
                pagos_fallidos,
                riesgo_baja_actividad,
                riesgo_pagos_fallidos,
                riesgo_proximo_vencimiento,
                riesgo_antiguo_inactivo,
                (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) AS puntaje_riesgo,
                CASE 
                    WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) >= 3 THEN 'Muy Alto - Contactar inmediatamente'
                    WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) = 2 THEN 'Alto - Ofrecer descuento o engagement'
                    WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) = 1 THEN 'Medio - Monitorear'
                    ELSE 'Bajo - Sin acción inmediata'
                END AS nivel_riesgo,
                CONCAT(
                    CASE WHEN riesgo_baja_actividad = 1 THEN 'Baja actividad. ' ELSE '' END,
                    CASE WHEN riesgo_pagos_fallidos = 1 THEN 'Pagos fallidos. ' ELSE '' END,
                    CASE WHEN riesgo_proximo_vencimiento = 1 THEN 'Suscripción por vencer. ' ELSE '' END,
                    CASE WHEN riesgo_antiguo_inactivo = 1 THEN 'Antiguo e inactivo. ' ELSE '' END,
                    CASE WHEN (riesgo_baja_actividad + riesgo_pagos_fallidos + riesgo_proximo_vencimiento + riesgo_antiguo_inactivo) = 0 
                         THEN 'Cliente saludable.' ELSE '' END
                ) AS recomendacion
            FROM RiesgoCalculado
        )
        
        -- Volcamos a una tabla temporal limpia
        SELECT 
            id_cliente, email, pais, edad, nombre_plan, fecha_inicio, fecha_fin,
            dias_activo, promedio_minutos, pagos_fallidos, puntaje_riesgo, 
            nivel_riesgo, recomendacion
        INTO #TempResultados
        FROM RiesgoFinal
        WHERE (@MostrarSoloRiesgo = 0 OR puntaje_riesgo > 0);

        -- Guardar en tabla histórica si el parámetro lo indica
        IF @GuardarHistorico = 1
        BEGIN
            INSERT INTO core.ReporteRiesgoHistorico (
                fecha_ejecucion, fecha_corte_analisis, id_cliente, email, pais, 
                edad, nombre_plan, fecha_inicio, fecha_fin, dias_activo, 
                promedio_minutos, pagos_fallidos, puntaje_riesgo, nivel_riesgo, recomendacion
            )
            SELECT 
                GETDATE(), @FechaCorte, id_cliente, email, pais, 
                edad, nombre_plan, fecha_inicio, fecha_fin, dias_activo, 
                promedio_minutos, pagos_fallidos, puntaje_riesgo, nivel_riesgo, recomendacion
            FROM #TempResultados;
        END

        -- Retornar resultados en pantalla
        SELECT * FROM #TempResultados 
        ORDER BY puntaje_riesgo DESC, promedio_minutos ASC;

        -- Buenas prácticas: Limpiar memoria
        DROP TABLE #TempResultados;

    END TRY
    BEGIN CATCH
        -- Control robusto de errores
        SELECT 
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage,
            ERROR_LINE() AS ErrorLine;
    END CATCH
END
GO

-- ==============================================================================
-- 3. EJEMPLOS DE USO PROFESIONAL (¡Pruébalo!)
-- ==============================================================================

 -- Ejemplo 1: Ejecución estándar, guardando en historial
EXEC sp_reporte_clientes_riesgo;

 -- Ejemplo 2: Reporte exclusivo para usuarios de Colombia (Asumiendo que Colombia es ID 5)
EXEC sp_reporte_clientes_riesgo @filtro_id_pais = 5, @GuardarHistorico = 0;

 -- Ejemplo 3: Consultar cómo se está llenando la tabla de historial
SELECT * FROM core.ReporteRiesgoHistorico ORDER BY id_reporte DESC;
