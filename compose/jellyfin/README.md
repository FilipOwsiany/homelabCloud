# Jellyfin

Ten stos uruchamia Jellyfin w oficjalnym kontenerze jako użytkownik bez uprawnień roota. Konfiguracja i baza aplikacji są zapisywane w `/srv/data/jellyfin/config`, cache w `/srv/data/jellyfin/cache`, a biblioteka `/srv/media` jest montowana do kontenera jako `/media` tylko do odczytu.

## Pierwsze uruchomienie

Wymagane są Linux, Docker Engine oraz plugin Docker Compose. Polecenia wykonuj z katalogu głównego repozytorium.

1. Utwórz lokalny plik środowiskowy:

   ```bash
   cp compose/jellyfin/.env.example compose/jellyfin/.env
   id -u
   id -g
   ```

   W `compose/jellyfin/.env` ustaw ścieżki oraz `JELLYFIN_UID` i `JELLYFIN_GID`. Wybrany użytkownik musi móc odczytać multimedia.

2. Przygotuj trwałe katalogi. Poniższy przykład pasuje do domyślnych wartości `UID=1000`, `GID=1000`:

   ```bash
   sudo install -d -o 1000 -g 1000 /srv/data/jellyfin/config
   sudo install -d -o 1000 -g 1000 /srv/data/jellyfin/cache
   sudo install -d /srv/media
   ```

   Nie zmieniaj właściciela istniejącej biblioteki w ciemno. W razie potrzeby nadaj użytkownikowi Jellyfin dostęp tylko do odczytu przez grupę lub ACL.

3. Sprawdź i uruchom stos:

   ```bash
   docker compose \
     --project-directory compose/jellyfin \
     --file compose/jellyfin/docker-compose.yml \
     config
   ./scripts/up.sh jellyfin
   docker compose \
     --project-directory compose/jellyfin \
     --file compose/jellyfin/docker-compose.yml \
     ps
   ```

4. Otwórz `http://ADRES_SERWERA:8096`, przejdź kreator i podczas dodawania biblioteki wybierz katalog pod `/media`, na przykład `/media/Filmy`.

Logi i zatrzymanie usługi:

```bash
docker logs --tail 100 jellyfin
./scripts/down.sh jellyfin
```

## Sieć i dostęp z zewnątrz

- `8096/tcp` udostępnia interfejs HTTP i API.
- `7359/udp` służy do wykrywania serwera w sieci lokalnej.
- DLNA wymaga trybu sieci hosta i nie jest włączone w tej przenośnej konfiguracji bridge.
- Przy dostępie spoza LAN użyj reverse proxy z HTTPS. Nie wystawiaj portu `8096` bezpośrednio do Internetu.

## Opcjonalne transkodowanie sprzętowe Intel/AMD

Najpierw sprawdź urządzenie i identyfikator grupy `render`:

```bash
ls -l /dev/dri/renderD128
getent group render | cut -d: -f3
```

Następnie wpisz otrzymany identyfikator jako `JELLYFIN_RENDER_GID` w `.env` i włącz lokalny override:

```bash
cp compose/jellyfin/docker-compose.override.yml.example \
  compose/jellyfin/docker-compose.override.yml
./scripts/up.sh jellyfin
```

W panelu Jellyfin przejdź do `Dashboard -> Playback -> Transcoding` i wybierz QSV dla wspieranego Intel GPU albo VA-API dla Intel/AMD. Konfiguracja NVIDIA i Rockchip wymaga innych urządzeń oraz ustawień; skorzystaj z [oficjalnej instrukcji akceleracji](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/).

## Backup

Wspólny skrypt zatrzymuje kontener na czas spójnej kopii katalogu `/config`:

```bash
sudo ./scripts/backup.sh jellyfin --output /mnt/backup/homelab
```

Cache nie jest kopiowany, bo Jellyfin może go odtworzyć. Biblioteka wskazana przez `JELLYFIN_MEDIA_ROOT` również nie jest częścią backupu repozytorium — zabezpiecz ją oddzielnym mechanizmem.

Podstawowa konfiguracja jest zgodna z [oficjalną instrukcją kontenera Jellyfin](https://jellyfin.org/docs/general/installation/container/).
