"""Account console assets served with a same-origin CSP."""

CSS = r'''
:root{color-scheme:light dark;--canvas:#edf2fb;--ink:#182842;--muted:#4a5c79;--accent:#4054b7;--accent-high:#4f63d6;--edge:#fff;--line:#718bb13d;--sheet:#ffffffa6;--sheet-end:#f6faff86;--field:#ffffffa8;--header:#f6f9ffd6;--shadow:#4b638629;--focus:#4a63cf;--good:#175d51;--good-bg:#d6f4eb;--caution:#7c5424;--caution-bg:#fff1d8;--radius:22px}
*{box-sizing:border-box}html{min-height:100%;scroll-behavior:smooth}body{margin:0;min-width:0;min-height:100vh;color:var(--ink);background:radial-gradient(ellipse at 4% 0%,#d8effcce,transparent 45%),radial-gradient(ellipse at 105% 38%,#dcd8f9a6,transparent 49%),var(--canvas);font:15px/1.64 'Noto Sans SC','PingFang SC','Microsoft YaHei',system-ui,sans-serif;-webkit-font-smoothing:antialiased}
button,input,select{font:inherit}a{color:var(--accent);text-underline-offset:4px}button{cursor:pointer}button:disabled{cursor:wait;opacity:.65}[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--focus);outline-offset:3px}.wrap{width:min(1120px,calc(100% - 64px));margin:0 auto;padding-top:26px}.wrap-text{overflow-wrap:anywhere}
.top{display:grid;grid-template-columns:1fr auto minmax(46px,1fr);align-items:center;gap:19px;min-height:62px;padding:10px 14px 10px 17px;margin:0 0 23px;border-radius:var(--radius);border:1px solid var(--edge);background:var(--header);box-shadow:0 10px 25px -20px var(--shadow),inset 0 1px 0 #fff6}
.brand{display:flex;align-items:center;gap:10px;min-width:0;text-decoration:none;color:var(--ink);font-size:17px;font-weight:740;letter-spacing:-.04em;line-height:1.2}.brand img{flex:none;display:block;object-fit:contain}.brand small{display:block;color:var(--muted);font-size:11px;font-weight:580;letter-spacing:.02em;margin-top:3px}
.nav-links{display:flex;justify-content:center;align-items:center;gap:5px;flex-wrap:wrap}.nav-links a,.nav-logout{min-height:37px;padding:7px 13px;display:inline-flex;justify-content:center;align-items:center;background:none;border:1px solid transparent;border-radius:11px;color:var(--muted);text-decoration:none;font-size:14px;font-weight:590;white-space:nowrap}.nav-links a[aria-current]{color:var(--accent);background:#8294de20;border-color:#788ac325}.nav-links a:hover,.nav-logout:hover{background:#8194cd14}.top>form{justify-self:end}.skip{position:absolute;inset:8px auto auto 12px;z-index:10;padding:9px 16px;background:var(--canvas);transform:translateY(-140%)}.skip:focus{transform:none}
h1,h2,h3,p{margin:0}h1,h2,h3{line-height:1.2;font-weight:740;letter-spacing:-.037em;overflow-wrap:anywhere}h1{font-size:clamp(32px,5vw,56px)}h2{font-size:clamp(22px,3vw,31px)}h3{font-size:24px}p{color:var(--muted)}.eyebrow{color:var(--accent);font-size:13px;font-weight:750;letter-spacing:.085em;line-height:1.3}.icon{width:20px;height:20px;flex:none;vertical-align:middle}
.sheet{border:1px solid var(--edge);border-radius:var(--radius);background:linear-gradient(145deg,var(--sheet),var(--sheet-end));box-shadow:0 18px 35px -26px var(--shadow),inset 0 1px 0 #fff6;min-width:0}
.hero{display:grid;grid-template-columns:minmax(0,2.08fr) minmax(0,1fr);gap:15px}.hero-main{min-height:269px;position:relative;isolation:isolate;overflow:hidden;display:flex;align-items:center;border-radius:var(--radius);border:1px solid #fffd;background:radial-gradient(ellipse at 90% 0%,#ece7ff,transparent 65%),radial-gradient(ellipse at 99% 102%,#bdd7fd,transparent 65%),linear-gradient(125deg,#f7fcff 10%,#dae6ff 75%,#b7c6f2);box-shadow:0 21px 48px -29px #536baf68,inset 0 1px 0 #fff}
.hero-copy{position:relative;padding:35px clamp(27px,4.6vw,56px);max-width:78%;z-index:1}.hero-copy .eyebrow{color:#3b50a5}.hero-copy h1{margin:9px 0 10px;color:#172a51}.hero-copy>p:not(.eyebrow){color:#41547b;font-size:16px;max-width:29em}.hero-copy .button{margin-top:23px}.hero-orbits{position:absolute;pointer-events:none;right:-13%;top:-38%;width:62%;height:184%;transform:rotate(-38deg);border-radius:50%;border:1px solid #fff8;box-shadow:0 0 0 23px #fff4,0 0 0 53px #fff4,0 0 0 85px #fff3;background:radial-gradient(ellipse at 58% 40%,#fbffffcf 0 2%,#c3eff45e 19%,#b1c6f14a 37%,transparent 66%)}
.hero-orbits::after{content:'';position:absolute;inset:22% 12%;border-radius:50%;box-shadow:inset 0 5px 19px #fff8,0 0 37px #d4ffff9f;background:linear-gradient(144deg,#f5ffff8f,#d1d3f54a 62%,transparent);border:1px solid #f4fcff80}.hero-status{display:flex;flex-direction:column;justify-content:center;gap:13px;padding:28px clamp(20px,3vw,32px)}.status-line{display:flex;align-items:center;gap:13px}.status-line h2{font-size:29px}.round-cloud,.plan-glyph,.mini-icon{display:grid;place-items:center;flex:none;width:45px;height:45px;border:1px solid #fff;border-radius:15px;color:#405cc2;background:linear-gradient(135deg,#fbfdff,#d9e7ff);box-shadow:0 7px 13px -9px #293e9099,inset 0 1px 0 white}
dl{margin:0}.hero-status dl{display:flex;justify-content:space-between;align-items:baseline;gap:14px;border-top:1px solid var(--line);padding-top:10px;font-size:14px}.hero-status dt{color:var(--muted)}dd{margin:0;font-weight:650;min-width:0;overflow-wrap:anywhere}.hero-tag{align-self:flex-start;background:var(--field);color:var(--muted);font-size:13px;font-weight:620;border:1px solid var(--line);padding:4px 10px;border-radius:999px}
.section{margin-top:29px;scroll-margin-top:20px}.section-head{display:flex;justify-content:space-between;align-items:end;gap:15px;margin:0 0 14px}.section-head h2{margin-top:6px}.section-head>p{font-weight:620}.plan-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:15px}.plan{position:relative;isolation:isolate;overflow:hidden;display:flex;flex-direction:column;gap:10px;min-width:0;padding:clamp(22px,3.4vw,35px);border-radius:var(--radius);border:1px solid #fff;background:linear-gradient(145deg,#f7fbff,#e1ecff 68%);box-shadow:0 20px 37px -28px #4b62b368,inset 0 1px 0 white;color:#182842}
.plan::before{content:'';position:absolute;pointer-events:none;z-index:-1;right:-19%;top:-28%;width:69%;height:110%;border-radius:50%;transform:rotate(-28deg);border:1px solid #fffb;box-shadow:0 0 0 26px #fff5,0 0 0 56px #fff2,inset 0 0 35px #fbffff;opacity:.67;background:radial-gradient(ellipse,#b9e9ff9c,transparent 61%)}
.plan.annual{border-color:#fbfaff;background:radial-gradient(ellipse at 100% 10%,#cbd7ff66,transparent 60%),linear-gradient(143deg,#faf9ff,#e6e5ff 67%,#e5eeff)}.plan.annual::before{background:radial-gradient(ellipse,#c3afffed 1%,#aaccf967 38%,transparent 70%)}.plan-top{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:4px}.plan-glyph{width:43px;height:43px;border-radius:14px}.plan-flag{background:#f3f3ff;color:#4254a9;border:1px solid #b3bce9;box-shadow:0 3px 9px -5px #667bc9aa;padding:4px 11px;border-radius:99px;font-size:13px;font-weight:720}
.plan h3 span{margin-left:11px;color:#465a83;font-size:14px;font-weight:650;letter-spacing:0}.price{display:flex;align-items:baseline;gap:6px;margin:3px 0;color:#192e5a}.price .currency{font-size:26px;font-weight:690;align-self:center}.price strong{font:690 clamp(45px,5.4vw,67px)/1 'Segoe UI',system-ui,sans-serif;letter-spacing:-.07em;font-variant-numeric:tabular-nums}.price .once{font-size:13px;margin-left:5px;color:#485d86;font-weight:650}.plan p,.plan-detail{color:#435574}.plan-detail{display:flex;align-items:center;gap:6px;padding-top:2px;font-size:14px}.plan-detail .icon{width:17px;height:17px;color:#335da9}.plan form{margin-top:auto;padding-top:12px}.plan>.button{margin-top:12px}.plan :is(form .button,.button){width:100%;justify-content:space-between}.plan form .button{min-height:48px}.terms-note{margin-top:12px;font-size:13px}
.button{display:inline-flex;align-items:center;justify-content:center;gap:9px;min-height:44px;padding:9px 15px;border:1px solid transparent;border-radius:12px;font-size:14px;font-weight:680;text-decoration:none;line-height:1.4;color:var(--ink);background:var(--field);text-align:center}.button:hover{filter:brightness(1.06)}.button.primary{color:white;background:linear-gradient(145deg,#566bd8,#4356b9);border-color:#465ac6;box-shadow:inset 0 1px 0 #e1eeff63,0 11px 19px -12px #394fbbb9}.annual .primary{background:linear-gradient(143deg,#6268dc,#474ec0);border-color:#5055c5}.button.secondary{background:var(--field);border-color:var(--line);box-shadow:inset 0 1px 0 #fffa}.button.unavailable{color:#566581;background:#f9fbff87;border-color:#9aaac355}.button.small{min-height:36px;padding:6px 11px;font-size:13px}.button.destructive{color:#812e41;border-color:#bc7588;background:#fadce5}.button:active{transform:translateY(1px)}
.bottom-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:15px;margin-top:23px}.mini{padding:25px clamp(21px,3.3vw,34px);scroll-margin-top:20px}.mini-icon{width:40px;height:40px;border-radius:13px}.mini h2{font-size:22px;margin:10px 0 8px}.mini .button{margin-top:13px}.mini p+p{margin-top:7px}.mini .keep-file{font-weight:650;color:var(--ink)}[data-export-status]:empty{display:none}[data-export-status]{margin-top:9px}.notice{padding:10px 14px;margin:12px 0;border:1px solid var(--line);border-radius:12px;background:var(--field);color:var(--ink)}
.mini .privacy-copy{margin-top:12px;font-size:14px}
.page-head{margin:14px 0 20px}.page-head h1{font-size:clamp(29px,5vw,44px);margin:7px 0 10px}.page-head>p:not(.eyebrow){font-size:16px;max-width:60ch}.compact-sheet{max-width:680px;padding:35px;margin:25px auto}.compact-sheet .page-head{margin-top:0}.compact-sheet .button{margin-top:15px}.back{display:inline-block;padding:4px 0;font-weight:650}
.list{padding:8px 24px}.order,.admin-row,.device-row,.audit-row{display:flex;justify-content:space-between;align-items:flex-start;gap:15px;padding:18px 0;border-bottom:1px solid var(--line);min-width:0}.list article:last-of-type,.device-row:last-of-type,.audit-row:last-of-type{border-bottom:0}.order h2{font-size:20px;margin-bottom:6px}.order p,.admin-row p,.device-row p{font-size:14px;margin-top:3px}.order-id,.identity-list code,.recovery-key{overflow-wrap:anywhere;user-select:all;font:13px/1.55 ui-monospace,Consolas,monospace}.order-id{color:var(--muted);display:inline-block;margin-top:5px}.order-side{display:flex;flex-direction:column;align-items:flex-end;gap:6px;text-align:right}.order-side>strong{font-size:22px;line-height:1;font-variant-numeric:tabular-nums}.status{display:inline-flex;gap:6px;align-items:center;flex:none;white-space:nowrap;padding:4px 9px;background:var(--field);border:1px solid var(--line);border-radius:99px;color:var(--muted);font-size:12px;font-weight:700;line-height:1.25}.status i{width:6px;height:6px;border-radius:50%;background:currentColor}.status.success{background:var(--good-bg);color:var(--good);border-color:transparent}.status.warning{background:var(--caution-bg);color:var(--caution);border-color:transparent}.row-actions{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:7px;margin-top:5px}.empty{padding:28px 0 32px}.empty h2{font-size:24px;margin-bottom:8px}.empty .button{margin-top:15px}.empty-line{padding:13px 0}
.settings-grid{margin:0}.inline-meta{display:flex;align-items:center;flex-wrap:wrap;gap:9px;margin:8px 0}.inline-meta h2{margin:0}.identity-list{display:grid;grid-template-columns:minmax(80px,max-content) 1fr;gap:7px 13px;margin-top:13px;padding-top:13px;border-top:1px solid var(--line);font-size:14px}.identity-list dt{color:var(--muted)}.setting{border-top:1px solid var(--line);padding:12px 0}.settings-list{padding:22px 27px}.settings-list>h2{font-size:22px;margin-bottom:10px}.setting summary,.device-action summary{cursor:pointer;font-weight:675;min-height:35px;line-height:35px}.setting p{margin:4px 0 12px}.setting form{max-width:520px}.field{display:block;color:var(--muted);font-size:14px;font-weight:650;margin-bottom:10px}.field input,.search input{display:block;width:100%;height:43px;margin-top:4px;padding:8px 11px;border:1px solid #7a8bab93;border-radius:10px;background:var(--field);color:var(--ink);font-size:16px;min-width:0}.setting form .button{margin-top:6px}.device-row{align-items:start}.device-action{flex:none;text-align:right}.device-action form{text-align:left;max-width:170px}.danger summary{color:#973e57}.recovery-key{display:block;margin:15px 0;padding:18px;border:1px solid var(--line);border-radius:12px;background:var(--field);font-size:16px}
.admin-row{display:grid;grid-template-columns:minmax(0,1fr) auto auto;align-items:center}.user-link{font-weight:720;overflow-wrap:anywhere}.search{display:flex;align-items:end;gap:10px;padding:14px 0;border-bottom:1px solid var(--line)}.search label{flex:1;min-width:0;font-size:14px;font-weight:660}.search .button{min-height:43px}.pagination{display:flex;gap:18px;padding:12px 0}.audit-row{padding:10px 0;font-size:14px;overflow-wrap:anywhere}.audit-row time{color:var(--muted);white-space:nowrap}
footer{display:flex;justify-content:space-between;align-items:center;gap:16px;margin:27px 0 0;padding:18px 0 25px;border-top:1px solid var(--line);font-size:13px;color:var(--muted)}footer>span{font-weight:700}footer nav{display:flex;flex-wrap:wrap;gap:14px}footer a{color:inherit}
@media(prefers-color-scheme:dark){:root{--canvas:#0e1729;--ink:#edf3ff;--muted:#bfcee7;--accent:#c3d0ff;--accent-high:#a6b7fe;--edge:#8fa8d567;--line:#99aed147;--sheet:#233453dd;--sheet-end:#182641bd;--field:#293b58;--header:#1b2942;--shadow:#03091485;--focus:#c2cfff;--good-bg:#203f3d;--good:#bcf3df;--caution-bg:#473b33;--caution:#ffdbb1}body{background:radial-gradient(ellipse at 4% 0%,#1d3e6070,transparent 48%),radial-gradient(ellipse at 105% 38%,#362b626b,transparent 52%),var(--canvas)}.sheet,.top,.button.secondary{box-shadow:inset 0 1px 0 #ffe5}.hero-main,.plan{border-color:#b9ccf0}.hero-copy .eyebrow{color:#314789}.plan .button.secondary{background:#eaf1ff;color:#202d4b;border-color:#9baed2}.danger summary{color:#ffb6cd}}
@media(max-width:800px){.wrap{width:calc(100% - 36px);padding-top:15px}.hero{grid-template-columns:minmax(0,1.5fr) minmax(0,1fr)}.hero-copy{max-width:100%}.hero-orbits{opacity:.61}.section-head{align-items:start}}
@media(max-width:620px){.wrap{width:calc(100% - 28px);padding-top:12px}.top{grid-template-columns:minmax(0,1fr) auto;gap:6px;padding:10px 10px 8px 12px;margin-bottom:15px}.top>form{grid-row:1;grid-column:2}.nav-links{grid-column:1/-1;grid-row:2;justify-content:flex-start;border-top:1px solid var(--line);padding-top:7px;margin-top:4px}.nav-links a,.nav-logout{min-height:37px;padding:6px 13px}.hero{display:block}.hero-main{min-height:220px}.hero-copy{padding:24px 21px}.hero-copy>p:not(.eyebrow){font-size:15px}.hero-copy .button{margin-top:16px}.hero-orbits{right:-26%;top:-38%;width:86%}.hero-status{margin-top:10px;padding:17px 20px;gap:8px}.hero-status .eyebrow{font-size:12px}.status-line h2{font-size:24px}.round-cloud{width:35px;height:35px;border-radius:12px}.hero-status dl{padding-top:7px}.hero-tag{display:none}.section{margin-top:23px}.plan-grid,.bottom-grid{grid-template-columns:minmax(0,1fr);gap:11px}.section-head{flex-wrap:wrap;gap:5px}.section-head>p,.terms-note{font-size:13px}.plan{padding:20px 22px;gap:8px}.plan-top{margin:0}.price{margin:0}.plan form{padding-top:7px}.plan .once{font-size:12px}.mini,.settings-list,.compact-sheet{padding:18px 19px}.list{padding:5px 17px}.order{display:block}.order-side{text-align:left;flex-direction:row;flex-wrap:wrap;align-items:center;margin-top:13px}.row-actions{flex-basis:100%;justify-content:flex-start}.admin-row{grid-template-columns:minmax(0,1fr) auto;gap:9px}.admin-row .button{display:none}.audit-row{display:block}.audit-row time{display:block}.search .button .icon{display:none}footer{margin-top:21px;align-items:start}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important;animation:none!important}}
@media(forced-colors:active){.hero-orbits,.plan::before{display:none}.sheet,.top,.plan,.hero-main,.button,.status{border:1px solid CanvasText}}
'''

CALENDAR_JS = r'''
(() => {
  const area = document.querySelector('[data-export]');
  if (!area) return;
  const start = area.querySelector('[data-prepare]');
  const intro = area.querySelector('[data-export-intro]');
  const save = area.querySelector('[data-save]');
  const confirm = area.querySelector('[data-confirm]');
  const status = area.querySelector('[data-export-status]');
  const headers = {'X-WeekGlass-CSRF': area.dataset.csrf};
  const base = '/account/calendar/';
  let claim, busy = false;
  const descriptions = {
    export_already_completed: '本次日程已导出。请保留已保存的文件。',
    export_use_active_download: '同步权益已恢复，刷新页面后可正常下载日程。',
    export_boundary_changed: '当前文件已无法恢复。请通过隐私政策中的联系渠道申请个人信息副本。',
    export_not_transferred: '日程文件未完整传输。请重新下载后再确认。',
    export_busy: '当前下载较多，请过几秒重试。导出机会仍保留。',
    invalid_csrf: '页面已失效，请刷新后继续。',
    unauthenticated: '登录已失效，请重新登录后继续。',
  };
  async function request(path) {
    const result = await fetch(base + path, {method: 'POST', headers, credentials: 'same-origin'});
    if (!result.ok) {
      const code = await result.json().then(data => data.code).catch(() => '');
      throw new Error(descriptions[code] || '');
    }
    return result;
  }
  async function acknowledge() {
    try {
      await request(claim + '/complete');
      confirm.hidden = true;
      status.textContent = '日程文件已下载。请妥善保存，本页关闭前可再次保存同一文件。';
    } catch {
      confirm.hidden = false;
      status.textContent = '文件已下载，暂未确认。可以重试确认，无需重新下载。';
    }
  }
  function lock(value) {
    busy = value;
    start.disabled = confirm.disabled = value;
  }
  start.addEventListener('click', async () => {
    if (busy) return;
    lock(true);
    confirm.hidden = true;
    status.textContent = '正在准备日程文件…';
    try {
      ({export_id: claim} = await (await request('prepare')).json());
      const response = await request(claim + '/download');
      const length = Number(response.headers.get('Content-Length'));
      const file = await response.blob();
      if (!Number.isSafeInteger(length) || length <= 0 || file.size !== length) throw new Error();
      save.href = URL.createObjectURL(file);
      save.hidden = false;
      start.hidden = true;
      intro.hidden = true;
      save.click();
      await acknowledge();
    } catch (error) {
      status.textContent = error.message || '日程文件未完整保存，导出机会仍保留。请重试。';
    } finally {
      lock(false);
    }
  });
  confirm.addEventListener('click', async () => {
    if (busy || !claim) return;
    lock(true);
    try { await acknowledge(); }
    finally { lock(false); }
  });
})();
'''
