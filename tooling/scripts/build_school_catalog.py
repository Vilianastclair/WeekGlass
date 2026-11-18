"""Rebuild the bundled school entry list. This does not contact school servers.

Run from any directory. Inputs are version-pinned public catalogs. Names and
URLs come from timetable (MIT) and official university publications; Sleepy
is a cross-check for the school name, HTTPS host and software family.
Entries are navigation shortcuts, not a list of account-tested integrations.
"""
import json
import re
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = "https://raw.githubusercontent.com/baoozak/timetable/e4b57dfa63359320ad0642aaf8c1f703e9236101/utils/schools.json"
CROSSCHECK = "https://raw.githubusercontent.com/lingion/sleepy/d0567a2602d098671fbfeaa44b03c0ce1433b4d7/app/src/main/assets/schools.json"
OFFICIAL = {
    # https://bksy.shu.edu.cn/info/1015/319614.htm
    "上海大学": "https://jwxt.shu.edu.cn/",
    # https://www.seiee.sjtu.edu.cn/upload/ueditor/file/20221122/1669082432713459.pdf
    "上海交通大学": "https://i.sjtu.edu.cn/",
    # https://jiaowuchu.buct.edu.cn/2026/0828/c610a222457/pagem.htm
    "北京化工大学": "https://jwglxt.buct.edu.cn/",
    # https://zdbk.zju.edu.cn/jwglxt/xtgl/xwck_ckLoginNews.html?doType=save&xwbh=569D011381027E3FE06329B3CA0A448F
    "浙江大学": "https://zdbk.zju.edu.cn/",
}
FAMILIES = {"zf_new": "zhengfang_new", "qz": "qiangzhi", "qz_with_node": "qiangzhi"}


def build(records, checks):
    corroborated = set()
    for row in checks:
        uri = urlsplit(row.get("url") or "")
        if uri.scheme == "https" and row.get("type") in FAMILIES:
            corroborated.add((row["name"], uri.hostname, FAMILIES[row["type"]]))
    entries = dict(OFFICIAL)
    for row in records:
        name, url = row["name"], row["url"]
        u = urlsplit(url)
        if ((name, u.hostname, row["type"]) not in corroborated or
                not u.hostname or not u.hostname.endswith(".edu.cn") or
                u.scheme != "https" or u.port not in (443, None) or
                u.query or u.fragment or u.username or u.password or
                re.search(r"vpn|atrust|^cas[.]|^auth|^sso[.]", u.hostname) or
                not re.fullmatch(r"/[a-zA-Z0-9_./-]*", u.path) or
                ".." in u.path or name == "武汉大学"):
            continue
        entries.setdefault(name, url)
    return entries


def literal(value):
    return json.dumps(value, ensure_ascii=False).replace("$", r"\$")


def main():
    # Preserve the original entry point without overwriting the school bindings
    # with the old two-family directory.
    from build_wakeup_bindings import main as rebuild
    rebuild()

if __name__ == "__main__":
    main()
