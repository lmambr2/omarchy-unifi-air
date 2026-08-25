# Map a Protect bootstrap or Integration API payload to the widget's
# sensor list. --arg want <name> (empty = first air sensor).
# --arg source bootstrap|integration

def metric($m):
  if ($m | type) != "object" then {value: null, status: ""}
  else {value: ($m.value // null), status: ($m.status // "")} end;

def is_air:
  ((.airQuality | type) == "object")
  or (((.type // .model // .productModel // .sku // "")
        | ascii_upcase | gsub("[^A-Z0-9]"; "")) == "UPAIRQUALITY");

def connected:
  if .isConnected != null then .isConnected
  elif .state != null then .state == "CONNECTED"
  else true end;

def row:
  {
    id: (.id // ""),
    name: (.name // "Air Quality"),
    connected: connected,
    aqi: metric(.airQuality.aqi // .stats.aqi),
    co2: metric(.airQuality.co2 // .stats.co2),
    humidity: metric(.airQuality.humidity // .stats.humidity),
    temperature: metric(.airQuality.temperature // .stats.temperature),
    pm1: metric(.airQuality.pm1p0 // .stats.pm1p0),
    pm25: metric(.airQuality.pm2p5 // .stats.pm2p5),
    pm4: metric(.airQuality.pm4p0 // .stats.pm4p0),
    pm10: metric(.airQuality.pm10p0 // .stats.pm10p0),
    voc: metric(.airQuality.voc // .stats.voc),
    tvoc: metric(.airQuality.tvoc // .stats.tvoc),
    vape: metric(.airQuality.vape // .stats.vape)
  };

def pick:
  if $want == "" then . else map(select(.name == $want)) end;

if $source == "integration" then
  (if type == "array" then . else (.sensors // .data // []) end)
  | map(select(is_air))
  | map(row)
  | pick
else
  (.sensors // .data.sensors // [])
  | map(select(is_air))
  | map(row)
  | pick
end
