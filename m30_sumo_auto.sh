#!/bin/bash
set -e

echo "=== 1. Descargando datos de tráfico del Ayuntamiento de Madrid ==="
URL="https://datos.madrid.es/egob/catalogo/212504-0-trafico-intensidad-tiempo-real.csv"
wget -O trafico_madrid.csv "$URL"

echo "=== 2. Filtrando sensores de la M-30 ==="
python3 << 'EOF'
import pandas as pd

df = pd.read_csv("trafico_madrid.csv", sep=';')

# Detectar columnas automáticamente
col_lat = [c for c in df.columns if "lat" in c.lower()][0]
col_lon = [c for c in df.columns if "lon" in c.lower()][0]
col_int = [c for c in df.columns if "int" in c.lower()][0]
col_ubic = [c for c in df.columns if "ub" in c.lower() or "desc" in c.lower()][0]

df_m30 = df[df[col_ubic].str.contains("M-30", case=False, na=False)]
df_m30.to_csv("trafico_m30.csv", index=False)

print("Sensores M-30 encontrados:", len(df_m30))
EOF

echo "=== 3. Descargando mapa OSM (Madrid completo) ==="
wget -O m30.osm "https://overpass-api.de/api/map?bbox=-3.80,40.25,-3.55,40.52"

echo "=== 4. Generando red SUMO m30.net.xml ==="
netconvert --osm-files m30.osm -o m30.net.xml

echo "=== 5. Generando trips desde datos reales ==="
python3 << 'EOF'
import pandas as pd
from sumolib import net
from xml.etree.ElementTree import Element, SubElement, ElementTree

NET = "m30.net.xml"
CSV = "trafico_m30.csv"
SIM_HOURS = 1  # 1 hora de simulación

df = pd.read_csv(CSV)

# detectar columnas
col_lat = [c for c in df.columns if "lat" in c.lower()][0]
col_lon = [c for c in df.columns if "lon" in c.lower()][0]
col_int = [c for c in df.columns if "int" in c.lower()][0]

net = net.readNet(NET)
edges = [e.getID() for e in net.getEdges()]

root = Element("trips")
trip_id = 0

for _, row in df.iterrows():
    x, y = net.convertLonLat2XY(row[col_lon], row[col_lat])
    nearest = net.getNeighboringEdges(x, y, radius=70)
    if not nearest:
        continue

    edge_id = nearest[0][0].getID()
    intensity = row[col_int]
    vehs = max(1, int(intensity * SIM_HOURS))

    for i in range(vehs):
        depart = i * (3600 / vehs)
        SubElement(root, "trip", {
            "id": f"t{trip_id}",
            "from": edge_id,
            "to": edges[(trip_id * 37) % len(edges)],
            "depart": str(round(depart, 2))
        })
        trip_id += 1

tree = ElementTree(root)
tree.write("m30.trips.xml", encoding="utf-8", xml_declaration=True)

print("Vehículos generados:", trip_id)
EOF

echo "=== 6. Generando rutas SUMO m30.rou.xml ==="
duarouter -n m30.net.xml -t m30.trips.xml -o m30.rou.xml

echo "=== 7. Creando archivo de configuración SUMO ==="
cat > m30.sumocfg << 'EOF'
<configuration>
    <input>
        <net-file value="m30.net.xml"/>
        <route-files value="m30.rou.xml"/>
    </input>
    <time>
        <begin value="0"/>
        <end value="3600"/>
    </time>
</configuration>
EOF

echo "=== 8. Lanzando SUMO-GUI ==="
sumo-gui -c m30.sumocfg
