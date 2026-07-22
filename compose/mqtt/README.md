# Mosquitto MQTT

This stack runs Eclipse Mosquitto with authenticated MQTT TCP (`1883`) and MQTT-over-WebSockets (`9001`). Anonymous access is disabled and retained messages/persistent sessions are stored in `data/mosquitto.db`.

See the [complete migration guide](../../docs/MIGRATION_GUIDE.md#86-mosquitto-mqtt) for dependencies, backup/restore behavior, security, client reconfiguration, tests, and cutover steps.

## First-time setup only

From this directory, create the first password-file user:

```bash
mkdir -p config data log
docker run --rm -it \
  -v "$(pwd)/config:/mosquitto/config" \
  eclipse-mosquitto:2 \
  mosquitto_passwd -c /mosquitto/config/passwd ha
chmod 644 config/passwd config/mosquitto.conf
docker compose up -d
```

Do not use `-c` when adding later users because it overwrites the existing password file. Never commit `config/passwd`; the migration backup transfers it securely.

Do not expose ports `1883` or `9001` to the public Internet without adding TLS and appropriate network access controls.
