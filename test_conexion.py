import pyodbc

# Cadena de conexión estándar para desarrollo local con autenticación de Windows
conn_str = (
    "DRIVER={ODBC Driver 17 for SQL Server};"  # Si instalaste el 18, cambia el 17 por 18
    "SERVER=LOCALHOST;"                        # Tu servidor local. Si usas SQL Express puede ser 'LOCALHOST\SQLEXPRESS'
    "DATABASE=Streaming_Retention_Insights_v2;"
    "Trusted_Connection=yes;"                  # Usa tu usuario de Windows actual
    # "TrustServerCertificate=yes;"            # DESCOMENTA esta línea (quítale el #) si usas el Driver 18
)

print("[-] Intentando conectar a SQL Server...")

try:
    # Abrimos la conexión usando un 'with' para que se cierre sola al terminar
    with pyodbc.connect(conn_str) as conn:
        # El cursor nos permite ejecutar comandos SQL
        with conn.cursor() as cursor:
            # Ejecutamos una consulta nativa de SQL Server para validar la versión
            cursor.execute("SELECT @@VERSION;")
            row = cursor.fetchone()
            
            print("\n==================================================")
            print("[¡ÉXITO!] Python y SQL Server están conectados.")
            print("==================================================")
            print(f"Versión de tu motor detectada:\n{row[0]}")
            print("==================================================\n")
            
except Exception as e:
    print("\n==================================================")
    print(f"[X] ERROR DE CONEXIÓN: No se pudo conectar.")
    print("==================================================")
    print(f"Detalle del error: {e}")
    print("==================================================\n")