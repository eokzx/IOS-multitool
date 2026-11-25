# Multitool — SSH, SFTP, FTP i terminal na iOS

Natywna aplikacja iOS (SwiftUI) do zarządzania serwerami: pełny terminal SSH, menedżer plików SFTP/FTP/FTPS, monitor serwera, klucze w Secure Enclave i integracja z Tailscale. Wszystko w jednym miejscu, bez kont, chmury i subskrypcji.

## Funkcje

**Terminal SSH**
- Pełny emulator xterm-256color (SwiftTerm): kolory, vim, htop, tmux, obsługa myszy, linki
- Wiele sesji naraz (karty), sesje przetrwają przełączanie zakładek
- Pasek klawiszy nad klawiaturą: Esc, „lepkie” Ctrl i Alt, Tab, strzałki z autopowtarzaniem, `| ~ / - _ : ; * & $ > < \` { } [ ]`, Home/End/PgUp/PgDn, F1–F12
- Zoom czcionki gestem szczypania, 8 motywów (m.in. Dracula, Solarized, Nord, Gruvbox)
- Snippety, czyli zapisane polecenia wysyłane jednym dotknięciem
- Polecenie startowe (np. `tmux attach || tmux`), Enter po rozłączeniu łączy ponownie, automatyczne wznawianie po powrocie z tła
- Przekierowanie portów `-L` (localhost na iPhonie → host za serwerem)
- Host pośredni (ProxyJump / bastion), także łańcuchowo

**Pliki (SFTP, FTP, FTPS)**
- Przeglądanie z nawigacją okruszkową, sortowaniem, filtrem i ukrytymi plikami
- Wysyłanie plików i zdjęć/wideo, pobieranie z podglądem QuickLook (pliki trafiają do aplikacji Pliki → Multitool → Pobrane)
- Wbudowany edytor tekstu (bez „inteligentnych” cudzysłowów, które psują konfigi)
- Zmiana nazwy, usuwanie (także rekursywne), nowe foldery i pliki, `chmod` z wizualnym edytorem
- Przez SSH: pakowanie do `.tar.gz`, rozpakowywanie, „otwórz terminal w tym folderze”
- Własny klient FTP/FTPS (implicit TLS) na Network.framework: MLSD, LIST (Unix i Windows/IIS), EPSV/PASV, automatyczne wznawianie połączenia

**Monitor serwera (Linux)**
- CPU z wykresem na żywo, RAM, swap, dyski, transfer sieciowy, load average, uptime
- Lista procesów z SIGTERM/SIGKILL
- Wykonywanie pojedynczych poleceń z podglądem wyjścia i kodu wyjścia

**Bezpieczeństwo**
- Klucze **Secure Enclave** (P-256): generowane sprzętowo, nie do skopiowania, opcjonalnie Face ID przy każdym użyciu
- Klucze Ed25519 (generowanie, eksport) oraz import OpenSSH/PEM (Ed25519, ECDSA P-256/384/521)
- „ssh-copy-id” jednym dotknięciem: instalacja klucza w `~/.ssh/authorized_keys`
- Weryfikacja kluczy hostów jak w OpenSSH (TOFU + ostrzeżenie o zmianie klucza)
- Hasła, klucze i token Tailscale w pęku kluczy iOS (`ThisDeviceOnly`)
- Blokada aplikacji Face ID / kodem

**Tailscale**
- Lista urządzeń z tailnetu przez API (status online, OS, IP, MagicDNS)
- Dodawanie urządzenia jako serwera jednym dotknięciem
- Obsługa **Tailscale SSH** (logowanie metodą `none`, bez hasła)

**Pozostałe**
- Grupy, kolory, ulubione, wyszukiwarka, duplikowanie serwerów
- Szybkie połączenie (`user@host:port`) oraz linki `ssh://` i `sftp://` otwierane w aplikacji
- Eksport/import konfiguracji (bez sekretów)

## Wymagania

- iOS / iPadOS 17+
- Xcode 16 lub nowszy (do zbudowania)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (projekt `.xcodeproj` jest generowany z `project.yml`)

Zależności (Swift Package Manager, pobierane automatycznie):
- [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.x: SSH, SFTP, PTY, direct-tcpip
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.5.1: emulator terminala
- SwiftNIO / SwiftNIO SSH (fork używany przez Citadel)

## Budowanie na Macu

```bash
brew install xcodegen
cd multitool
xcodegen generate
open Multitool.xcodeproj
```

W Xcode: target **Multitool** → *Signing & Capabilities* → wybierz swój zespół (wystarczy darmowe Apple ID). W razie konfliktu zmień `PRODUCT_BUNDLE_IDENTIFIER`. Potem podłącz iPhone'a i naciśnij ⌘R.

## Budowanie bez Maca (Windows)

W repozytorium jest workflow GitHub Actions `.github/workflows/build-ios.yml`, który na maszynie macOS w chmurze generuje projekt i buduje **niepodpisany plik IPA**.

1. Wrzuć projekt do repozytorium na GitHubie (`git init`, `git add .`, `git commit`, `git push`).
2. Zakładka **Actions** → *Build iOS (unsigned IPA)* → poczekaj na zielony status (albo uruchom ręcznie przez *Run workflow*).
3. Pobierz artefakt **Multitool-unsigned-ipa**.
4. Zainstaluj na iPhonie przez [Sideloadly](https://sideloadly.io) lub [AltStore](https://altstore.io). Podpiszą IPA Twoim Apple ID. Z darmowym kontem aplikację trzeba odświeżać co 7 dni, z płatnym kontem deweloperskim co rok.

## Struktura projektu

```
Multitool/
├── App/          punkt wejścia, TabView, router, ekran blokady
├── Models/       ServerHost, klucze, snippety, ustawienia
├── Storage/      AppStore (JSON) + Keychain
├── Security/     blokada Face ID
├── SSH/          łączenie (jump host), auth, weryfikacja hostów, klucze, port forwarding
├── Terminal/     sesje PTY, SwiftTerm, pasek klawiszy, motywy, karty
├── Files/        przeglądarka plików, backend SFTP, klient FTP/FTPS, edytor
├── Monitor/      metryki serwera, procesy, wykonywanie poleceń
├── Hosts/        lista serwerów, edytor, szybkie połączenie, arkusze
├── Keys/         generowanie / import / eksport / instalacja kluczy
├── Snippets/     zapisane polecenia
├── Tailscale/    API Tailscale i lista urządzeń
├── Settings/     ustawienia, motywy, znane hosty, kopia zapasowa
└── Resources/    ikona i kolor akcentu
```

## Ograniczenia (do rozwinięcia)

- **Klucze RSA** nie są jeszcze obsługiwane (biblioteka nie udostępnia publicznego parsera). Wygeneruj w aplikacji Ed25519 lub klucz Secure Enclave i zainstaluj go na serwerze przyciskiem „Zainstaluj na serwerze”.
- **Klucze zaszyfrowane hasłem** trzeba przed importem odszyfrować: `ssh-keygen -p -N "" -f klucz`. W aplikacji klucz chroni i tak pęk kluczy iOS.
- **keyboard-interactive** (np. 2FA przez PAM) nie jest obsługiwane przez SwiftNIO SSH. Działają hasło, klucze i `none` (Tailscale SSH).
- **Praca w tle:** iOS zawiesza aplikacje po ok. 30 s w tle. Sesje mają wtedy dodatkowy czas, a po powrocie łączą się ponownie automatycznie. Do długich zadań używaj `tmux`.
- **FTPS:** obsługiwany tryb implicit (port 990). Serwery wymagające explicit `AUTH TLS` (port 21) lub wznawiania sesji TLS na kanale danych mogą nie działać.
- **Monitor serwera** zakłada Linuksa (`/proc`, GNU `ps`). Na innych systemach pokaże tylko część danych.
