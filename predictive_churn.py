import pyodbc
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import classification_report, confusion_matrix, accuracy_score

# ==============================================================================
# 1. CONFIGURACIÓN DE LA CONEXIÓN (Mismo puente del test anterior)
# ==============================================================================
conn_str = (
    "DRIVER={ODBC Driver 17 for SQL Server};" # Cambia a 18 si usas ese
    "SERVER=LOCALHOST;"
    "DATABASE=Streaming_Retention_Insights_v2;"
    "Trusted_Connection=yes;"
)

print("[-] Extrayendo datos desde SQL Server para el entrenamiento...")

# ==============================================================================
# 2. EXTRACCIÓN Y CONSTRUCCIÓN DEL DATASET (Query Optimizado)
# ==============================================================================
# Esta consulta une el comportamiento histórico, pagos y datos demográficos.
# Definimos Churn (1) si la suscripción NO está activa, y (0) si se mantiene activa.
query_dataset = """
WITH ResumenActividad AS (
    SELECT 
        id_cliente,
        AVG(CAST(minutos_escuchados AS FLOAT)) AS promedio_minutos
    FROM analytics.Actividad_Usuario
    GROUP BY id_cliente
),
ResumenPagos AS (
    SELECT 
        s.id_cliente,
        SUM(CASE WHEN p.estado_pago = 'fallido' THEN 1 ELSE 0 END) AS pagos_fallidos
    FROM core.Pagos p
    INNER JOIN core.Suscripciones s ON p.id_suscripcion = s.id_suscripcion
    GROUP BY s.id_cliente
)
SELECT 
    c.id_cliente,
    c.edad,
    c.id_pais,
    DATEDIFF(day, s.fecha_inicio, ISNULL(s.fecha_fin, '2026-06-18')) AS dias_activo,
    ISNULL(a.promedio_minutos, 0) AS promedio_minutos,
    ISNULL(p.pagos_fallidos, 0) AS pagos_fallidos,
    -- NUESTRO TARGET: 1 = Cancelado (Churn), 0 = Activo (Retenido)
    CASE WHEN s.estado = 'activa' THEN 0 ELSE 1 END AS Churn
FROM core.Clientes c
INNER JOIN core.Suscripciones s ON c.id_cliente = s.id_cliente
LEFT JOIN ResumenActividad a ON c.id_cliente = a.id_cliente
LEFT JOIN ResumenPagos p ON c.id_cliente = p.id_cliente;
"""

try:
    with pyodbc.connect(conn_str) as conn:
        df = pd.read_sql_query(query_dataset, conn)
    print(f"[+] Dataset cargado con éxito. Total registros para análisis: {df.shape[0]}\n")
    
except Exception as e:
    print(f"[X] Error al extraer datos: {e}")
    exit()

# ==============================================================================
# 3. DIVISIÓN DE DATOS (Entrenamiento vs. Evaluación)
# ==============================================================================
# X = Las características que causan la fuga (features)
# y = El resultado final (si se fugó o no - target)
X = df[['edad', 'id_pais', 'dias_activo', 'promedio_minutos', 'pagos_fallidos']]
y = df['Churn']

# Separamos el 80% de los datos para enseñar al modelo y el 20% para ponerlo a prueba
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.20, random_state=42, stratify=y)

# ==============================================================================
# 4. ENTRENAMIENTO DEL MODELO (Machine Learning)
# ==============================================================================
print("[-] Entrenando algoritmo Random Forest Classifier...")
model = RandomForestClassifier(n_estimators=100, random_state=42, max_depth=6)
model.fit(X_train, y_train)
print("[+] ¡Modelo entrenado y listo para evaluación!\n")

# ==============================================================================
# 5. EVALUACIÓN CIENTÍFICA DEL MODELO
# ==============================================================================
y_pred = model.predict(X_test)
accuracy = accuracy_score(y_test, y_pred)

print("=" * 60)
print(f"REPORTES DE RENDIMIENTO (Precisión Global: {accuracy:.2%})")
print("=" * 60)
print(classification_report(y_test, y_pred, target_names=['Retenido (0)', 'Fugado (1)']))

print("\n" + "=" * 60)
print("IMPORTANCIA DE LAS VARIABLES (¿Qué causa que los usuarios se vayan?)")
print("=" * 60)
importancias = model.feature_importances_
for var, imp in zip(X.columns, importancias):
    print(f" • Variable '{var}': aporta un {imp:.2%} a la decisión del modelo.")
print("=" * 60 + "\n")