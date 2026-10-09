#!/usr/bin/env python3
"""Pull Cloudflare traffic for the Transcripts site and write JSON results.

Runs in GitHub Actions with CLOUDFLARE_API_TOKEN. Tries several datasets and
keeps every error, so a scope problem is visible instead of silently empty.
Usage: site-traffic.py OUTPUT_DIR
"""
import datetime as dt
import json
import os
import sys
import urllib.request

API = "https://api.cloudflare.com/client/v4"
HOSTS = ["transcripts.doughatcher.com", "transcripts.hatcher.ltd"]
TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
OUT = sys.argv[1] if len(sys.argv) > 1 else "traffic"
TODAY = dt.date.today()
SINCE = os.environ.get("SINCE", "2026-09-20")  # launch window starts before the Sept 27 release


def call(path, body=None):
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"http_error": e.code, "body": e.read().decode()[:2000]}


def gql(query, variables):
    return call("/graphql", {"query": query, "variables": variables})


def days_ago(n):
    return (TODAY - dt.timedelta(days=n)).isoformat()


results = {"generated": dt.datetime.utcnow().isoformat() + "Z", "since": SINCE}
results["token_verify"] = call("/user/tokens/verify")
accounts = call("/accounts")
results["accounts"] = [{"id": a["id"], "name": a["name"]} for a in accounts.get("result") or []]
zones = {}
for name in ["doughatcher.com", "hatcher.ltd"]:
    z = call(f"/zones?name={name}")
    zones[name] = (z.get("result") or [{}])[0].get("id") if z.get("result") else None
    if not zones[name]:
        results.setdefault("zone_errors", {})[name] = z
results["zones"] = zones

# 1. Zone daily rollup (whole zone, long retention).
results["zone_daily"] = {}
for name, zid in zones.items():
    if zid:
        results["zone_daily"][name] = gql(
            """query($z:String!,$s:Date!,$e:Date!){viewer{zones(filter:{zoneTag:$z}){
              httpRequests1dGroups(limit:60,orderBy:[date_ASC],filter:{date_geq:$s,date_leq:$e}){
                dimensions{date} sum{requests pageViews threats} uniq{uniques}}}}}""",
            {"z": zid, "s": SINCE, "e": TODAY.isoformat()},
        )

# 2. Per-host adaptive traffic. Free plans keep only a few days, so try
#    progressively shorter windows and keep the first that works.
results["host_adaptive"] = {}
for host in HOSTS:
    zid = zones.get(host.split(".", 1)[1])
    if not zid:
        continue
    for window in [SINCE, days_ago(29), days_ago(7), days_ago(3), days_ago(1)]:
        filt = {"datetime_geq": f"{window}T00:00:00Z", "clientRequestHTTPHost": host}
        q = """query($z:String!,$f:ZoneHttpRequestsAdaptiveGroupsFilter_InputObject){viewer{zones(filter:{zoneTag:$z}){
            byDay: httpRequestsAdaptiveGroups(limit:100,filter:$f,orderBy:[date_ASC]){count dimensions{date} sum{visits edgeResponseBytes}}
            byRef: httpRequestsAdaptiveGroups(limit:25,filter:$f,orderBy:[sum_visits_DESC]){count sum{visits} dimensions{clientRefererHost}}
            byPath: httpRequestsAdaptiveGroups(limit:25,filter:$f,orderBy:[count_DESC]){count sum{visits} dimensions{clientRequestPath}}
            byCountry: httpRequestsAdaptiveGroups(limit:15,filter:$f,orderBy:[sum_visits_DESC]){count sum{visits} dimensions{clientCountryName}}
            byBot: httpRequestsAdaptiveGroups(limit:20,filter:$f,orderBy:[count_DESC]){count dimensions{userAgentBrowser clientRequestHTTPMethodName}}
          }}}"""
        r = gql(q, {"z": zid, "f": filt})
        results["host_adaptive"][host] = {"window_start": window, "result": r}
        if r.get("data") and not r.get("errors"):
            break

# 3. Cloudflare Web Analytics (RUM beacon), account level, if enabled.
results["web_analytics"] = {}
for acct in results["accounts"]:
    filt = {"datetime_geq": f"{SINCE}T00:00:00Z", "requestHost_in": HOSTS}
    results["web_analytics"][acct["id"]] = gql(
        """query($a:String!,$f:AccountRumPageloadEventsAdaptiveGroupsFilter_InputObject){viewer{accounts(filter:{accountTag:$a}){
          byDay: rumPageloadEventsAdaptiveGroups(limit:100,filter:$f,orderBy:[date_ASC]){count sum{visits} dimensions{date}}
          byRef: rumPageloadEventsAdaptiveGroups(limit:25,filter:$f,orderBy:[sum_visits_DESC]){count sum{visits} dimensions{refererHost}}
          byPath: rumPageloadEventsAdaptiveGroups(limit:25,filter:$f,orderBy:[count_DESC]){count dimensions{requestPath}}
          byCountry: rumPageloadEventsAdaptiveGroups(limit:15,filter:$f,orderBy:[sum_visits_DESC]){count sum{visits} dimensions{countryName}}
        }}}""",
        {"a": acct["id"], "f": filt},
    )
    results["web_analytics_sites"] = call(f"/accounts/{acct['id']}/rum/site_info/list")

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, f"cloudflare-{TODAY.isoformat()}.json"), "w") as f:
    json.dump(results, f, indent=1)
print("wrote", OUT)
