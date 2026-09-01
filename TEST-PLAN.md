# Test plán — `diag/connection-logging`

Stav k 1. 9. 2026. Vždy po testu **exportuj ConnDiag log**, i když všechno klaplo —
zdravý log je taky důkaz.

Legenda: ✅ ověřeno na motorce · ⏳ jen CI, neověřeno · ❓ nelze ověřit bez čekání

---

## A. PRIORITA 1 — hlavní podezřelý

### A1. Timeout na dashi po reconnectu ❓
**Proč:** Zmizel po wakelock fixu, ale **nemáme důkaz, že to byla ta příčina**.
Jediné, co rozhodne, je delší jízda s víc výpadky.

1. Spusť navigaci, telefon **do kapsy** (displej zhasnutý)
2. Vypni a zapni motorku — počkej na reconnect
3. **Opakuj aspoň 4×** během jedné jízdy
4. Sleduj dash: naskočí mapa, nebo Timeout?

| v logu | znamená |
|---|---|
| `RTP throughput: N fps ... conn=ready` opakovaně | ✅ rámce tečou |
| `⚠️ RTP throughput: 0.0 fps ... conn=ready` | enkodér/renderer mlčí |
| `⚠️ ... conn=waiting` / `conn=failed` | UDP se nespojilo |
| `fps > 0` **a přesto Timeout na dashi** | rámce tečou, chyba je v protokolu |

Ten poslední řádek je nejdůležitější — rozhodne, jestli hledat dál v appce, nebo v K1G.

---

## B. PRIORITA 2 — opraveno, ale jen jednou viděno

### B1. Wakelock přes reconnect ✅ (1×)
**Ověřeno:** appka v pozadí 09:14:47–09:16:15, 5 reconnectů, `waitForWifiReady`
držel strop 5,3 s (dřív 179 s).

Chce potvrdit na delší jízdě. V logu hlídej: mezi `Waiting for Wi-Fi` a
`Wi-Fi ready` **nikdy víc než ~6 s**. Když uvidíš desítky sekund, appka zase usnula.

### B2. Socket leak / druhý reconnect ⏳
**Commit:** `79d9088` — CI ✅, **na železe neověřeno**

1. Nech spadnout Wi-Fi **2× rychle po sobě** (vypni/zapni motorku dvakrát)
2. Dřív se druhý reconnect zasekl natrvalo na „reconnecting to dash"

**Otisk v logu:** po každém `step1 FAILED` musí následovat `DashSocket cancelled`.
Když chybí → fd leakl → fix nezabral.

### B3. Mrtvý streamer ✅
`ab10f11` — potvrzeno 29. 8. i 1. 9. Hlídej jen, že se nevrátí:
`Link left .connected with a non-running streamer` následované úspěšným startem.

---

## C. PRIORITA 3 — mapa, nikdy neověřeno v terénu

Všechny ⏳ (CI ✅). **Tady hrozí regrese** — smoothing zasahuje do zobrazení pozice.

### C1. Skok pozice o kilometry
`cd3b0a0` + `a8d7839` + `e75e750`

Jeď aspoň 30 min. Sleduj šipku na dashi — nesmí odskočit mimo silnici.

V logu (žádná z těchto řádek by neměla přijít často):
- `⚠️ motion interpolator drift N m` — občas OK (viděli jsme 101–148 m), soustavně ne
- `⚠️ tile-centre invariant violated` — **nemělo by se objevit vůbec**
- `⚠️ rider did not match any anchor within the continuity window`

### C2. SIGTRAP crash (NaN) ⏳
`7a559a5`. Nelze cíleně vyvolat. Jen: kdyby appka spadla, pošli MetricKit report.

### C3. Dlaždice na startu navigace ⏳
`bdce17b` + `27ead41` — po startu má být hned vidět mapa, ne prázdno.

---

## D. PRIORITA 4 — nav sekvence

### D1. Free-ride bez „press cast button" ✅
`359dc5d` + `1f69aec`. Spusť free-ride → musí naskočit mapa.

### D2. Nesmyslný HUD ve free-ride ❌ NEOPRAVENO
Známý bug: ve free-ride se ukazuje manévr + ETA (03:03). **Není v plánu opraveno** —
jen potvrď, jestli to pořád dělá.

### D3. GPX turn fix — **už v main** ✅ CI
`7647929` (PR #120). Ale **v terénu neověřeno**.

Naimportuj `<trk>` GPX (Ariho `Neville_Holt.gpx` nebo vlastní z Kurvigeru → Track).
Před fixem: u ostrých odboček „rovně" až do křižovatky. Po fixu: zobrazí se šipka.

⚠️ Neověřeno, že MKDirections vrací pro leg končící v zatáčce „arrive at destination".
Když fix nezabere, tohle je první podezřelý.

---

## E. Co v plánu NENÍ

- **12min freeze na pozadí** (`Bad file descriptor`) — neřešeno, možná souvisí s B2
- **GPS vs. pozice šipky** — logování jsme se rozhodli nepřidávat
- **Wi-Fi výpadek 3 min** (log 29. 8.) — appka se o join nepokouší, spoléhá na iOS
  auto-join. Nezkoumáno do konce.

---

## Minimální varianta (když bude málo času)

1. Navigace, telefon v kapse, **4× vypnout/zapnout motorku** → A1 + B1 + B2
2. Jeď 30 min v kuse → C1
3. Import GPX tracku → D3

To pokryje všechno, co je nejvíc rizikové.
