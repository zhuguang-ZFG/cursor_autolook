#!/usr/bin/env python3
"""Compare CC Switch SQLite Claude providers vs cc-switch-router.config.json."""

import json
import sqlite3
from pathlib import Path


def main() -> int:
    home = Path.home()
    db_path = home / ".cc-switch" / "cc-switch.db"
    cfg_path = home / ".claude" / "hooks" / "cc-switch-router.config.json"
    settings_path = home / ".cc-switch" / "settings.json"

    config: dict = {}
    if cfg_path.exists():
        config = json.loads(cfg_path.read_text(encoding="utf-8"))

    routes_by_target: dict[str, list[str]] = {}
    for tag, target in (config.get("routes") or {}).items():
        routes_by_target.setdefault(str(target), []).append(str(tag))

    providers_cfg = config.get("providers") or {}

    providers_meta: list[dict] = []
    if not db_path.exists():
        print(f"Missing DB: {db_path}")
        return 1

    con = sqlite3.connect(str(db_path))
    cur = con.cursor()
    cur.execute(
        """SELECT id, name, is_current, substr(settings_config, 1, 6000)
           FROM providers
           WHERE app_type = 'claude'
           ORDER BY is_current DESC, name"""
    )
    for pid, name, is_cur, sc in cur.fetchall():
        model, base_url = None, None
        if sc:
            try:
                obj = json.loads(sc)
                env = obj.get("env") or {}
                model = env.get("ANTHROPIC_MODEL") or env.get(
                    "ANTHROPIC_DEFAULT_SONNET_MODEL"
                )
                base_url = env.get("ANTHROPIC_BASE_URL")
            except json.JSONDecodeError:
                pass
        bu = str(base_url or "")
        local_hint = "127.0.0.1" in bu or "localhost" in bu.lower()

        pk = None
        for key, meta in providers_cfg.items():
            if isinstance(meta, dict) and meta.get("id") == pid:
                pk = str(key)
                break

        routes = routes_by_target.get(pk or "", []) if pk else []

        providers_meta.append(
            {
                "id": pid,
                "name": name,
                "is_current": bool(is_cur),
                "model": model,
                "base_url": base_url or "",
                "local_hint": local_hint,
                "provider_key": pk,
                "routes": routes,
            }
        )

    con.close()

    settings = {}
    if settings_path.exists():
        settings = json.loads(settings_path.read_text(encoding="utf-8"))

    current_id = settings.get("currentProviderClaude")

    print("=== currentProviderClaude (settings.json) ===")
    print(current_id)

    print(f"\n=== DB Claude providers (count={len(providers_meta)}) ===")
    missing_cfg = []
    local_rows = []
    for p in providers_meta:
        if not p["provider_key"]:
            missing_cfg.append(str(p["name"]))
        if p["local_hint"]:
            local_rows.append(p)

        mark = "*" if p["id"] == current_id else " "
        loc_tag = "[LOCAL-ish URL]" if p["local_hint"] else ""
        print(f"{mark} {p['id']} {p['name']} {loc_tag}".rstrip())

        if p["model"]:
            print(f"   model={p['model']}")
        if p["base_url"]:
            b = str(p["base_url"])
            print(f"   base_url={b}" if len(b) <= 100 else f"   base_url={b[:97]}...")
        print(f"   router_key={p['provider_key'] or 'NOT_IN_ROUTER_CONFIG'}")
        if p["routes"]:
            tags = p["routes"][:8]
            more = "..." if len(p["routes"]) > 8 else ""
            print(f"   tags={','.join(tags)}{more}")
        print()

    if missing_cfg:
        print("=== DB providers missing from router config (sync needed?) ===")
        for n in sorted(set(missing_cfg)):
            print(f" - {n}")
    else:
        print("=== All DB Claude providers mapped in router config (by id) ===")

    print("\n=== Local-backend candidates (127.0.0.1 / localhost in ANTHROPIC_BASE_URL) ===")
    if not local_rows:
        print("(none)")
    else:
        for p in local_rows:
            star = "*" if p["id"] == current_id else " "
            print(f"{star} {p['name']} | model={p['model']} | key={p['provider_key']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
