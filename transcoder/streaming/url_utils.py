from __future__ import annotations

from urllib.parse import urlparse, parse_qsl, urlencode, urlunparse


def _is_multicast_ip(ip: str) -> bool:
    try:
        first = int(ip.split(".")[0])
    except Exception:
        return False
    return 224 <= first <= 239


def build_udp_url(profile, target) -> str:
    """Normalize and enrich a UDP URL using profile defaults and target overrides.

    Rules:
    - Keep the base URL exactly as user provided (udp://host:port)
    - Merge query params (existing params win unless overridden explicitly by target overrides)
    - Apply defaults if missing: pkt_size, overrun_nonfatal, ttl (multicast)
    """
    raw = (target.target_url or "").strip()
    if not raw:
        raise ValueError("OutputTarget.target_url is empty")

    parsed = urlparse(raw)
    if parsed.scheme != "udp":
        # Phase 1-4 only support UDP MPEG-TS targets
        return raw

    q = dict(parse_qsl(parsed.query, keep_blank_values=True))

    # ----- pkt_size -----
    pkt_size = target.pkt_size if target.pkt_size is not None else getattr(profile, "default_pkt_size", None)
    if pkt_size and "pkt_size" not in q:
        q["pkt_size"] = str(pkt_size)

    # ----- overrun_nonfatal -----
    # allow explicit override by target (True/False); if None -> inherit profile default
    if target.overrun_nonfatal is not None:
        q["overrun_nonfatal"] = "1" if bool(target.overrun_nonfatal) else "0"
    else:
        if getattr(profile, "default_overrun_nonfatal", None) is True and "overrun_nonfatal" not in q:
            q["overrun_nonfatal"] = "1"

    # ----- fifo_size / buffer_size -----
    if target.fifo_size is not None and "fifo_size" not in q:
        q["fifo_size"] = str(target.fifo_size)
    if target.buffer_size is not None and "buffer_size" not in q:
        q["buffer_size"] = str(target.buffer_size)

    # ----- ttl (only if multicast) -----
    host = parsed.hostname or ""
    ttl_val = target.ttl if target.ttl is not None else getattr(profile, "default_ttl", None)
    if ttl_val and _is_multicast_ip(host) and "ttl" not in q:
        q["ttl"] = str(ttl_val)

    new_query = urlencode(sorted(q.items()), doseq=True)

    return urlunparse(parsed._replace(query=new_query))
