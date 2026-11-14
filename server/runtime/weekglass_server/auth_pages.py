"""Self-contained authorization pages: no third-party assets or scripts."""
import html
import base64
import hashlib

from .auth_styles import AUTH_BRAND, AUTH_STYLE


# A fixed, CSP-hashed script; no remote code or inline event handlers.
PASSWORD_SCRIPT = """document.querySelectorAll('[data-password-toggle]').forEach(function(button){button.hidden=false;button.addEventListener('click',function(){var input=document.getElementById(button.getAttribute('aria-controls'));var reveal=input.type==='password';input.type=reveal?'text':'password';button.textContent=reveal?'隐藏':'显示';button.setAttribute('aria-pressed',String(reveal));});});"""

# Progressive enhancement only: ordinary HTML form submission remains usable
# without JavaScript. Disable submit buttons, never successful input controls.
FORM_SCRIPT = PASSWORD_SCRIPT + r"""
(function(){
  var forms=Array.from(document.querySelectorAll('form[data-auth-form]'));
  var busy=false, timer=null;
  function reset(){
    busy=false;
    if(timer!==null){window.clearTimeout(timer);timer=null;}
    forms.forEach(function(form){
      form.removeAttribute('aria-busy');
      form.querySelectorAll('button[type="submit"]').forEach(function(button){
        button.disabled=false;
        if(button.dataset.readyLabel){button.textContent=button.dataset.readyLabel;}
      });
      var status=form.querySelector('[data-submit-status]');
      status.hidden=true;status.textContent='';
    });
  }
  forms.forEach(function(form){
    form.addEventListener('submit',function(event){
      if(busy){event.preventDefault();return;}
      busy=true;form.setAttribute('aria-busy','true');
      forms.forEach(function(other){other.querySelectorAll('button[type="submit"]').forEach(function(button){
        button.dataset.readyLabel=button.textContent;button.disabled=true;
      });});
      var button=form.querySelector('button[type="submit"]');
      var action=form.querySelector('input[name="action"]').value;
      button.textContent=action==='login'?'正在验证…':action==='register'?'正在创建账号…':action==='recover'?'正在重设密码…':'正在连接…';
      var status=form.querySelector('[data-submit-status]');
      status.hidden=false;status.textContent='正在安全提交，请稍候。';
      timer=window.setTimeout(function(){
        status.textContent='服务器仍未返回结果，请勿重复提交。如果长时间没有响应，请回到 WeekGlass 重新连接。';
      },15000);
    });
  });
  window.addEventListener('pageshow',function(event){if(event.persisted){reset();}});
})();"""

# The URL is rendered as escaped DOM data, never interpolated into JavaScript.
# This is a fresh document navigation after HTTP 200, not a form redirect.
HANDOFF_SCRIPT = r"""(function(){
  var link=document.getElementById('handoff-link');
  var status=document.getElementById('handoff-status');
  var target;
  try{
    target=new URL(link.href);
    var keys=Array.from(target.searchParams.keys());
    if(target.protocol!=='http:'||target.hostname!=='127.0.0.1'||Number(target.port)<1024||Number(target.port)>65535||target.pathname!=='/oauth/callback'||target.username||target.password||target.hash||keys.length!==2||target.searchParams.getAll('code').length!==1||target.searchParams.getAll('state').length!==1||!/^[-_A-Za-z0-9]{43}$/.test(target.searchParams.get('code')||'')||!target.searchParams.get('state')){throw new Error('invalid callback');}
  }catch(error){
    link.removeAttribute('href');link.setAttribute('aria-disabled','true');
    status.textContent='连接地址无效，请回到 WeekGlass 重新连接。';return;
  }
  var timer=window.setTimeout(function(){
    try{window.location.replace(target.href);}
    catch(error){status.textContent='浏览器未能自动返回，请点击下方按钮，或回到 WeekGlass 重新连接。';}
  },350);
  link.addEventListener('click',function(){window.clearTimeout(timer);});
})();"""


def _script_source(script):
    return "'sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode() + "'"


FORM_SCRIPT_SOURCE = _script_source(FORM_SCRIPT)
HANDOFF_SCRIPT_SOURCE = _script_source(HANDOFF_SCRIPT)


def _escape(value):
    return html.escape(value, quote=True)


def _hidden(csrf, action):
    return (f'<input type="hidden" name="csrf" value="{_escape(csrf)}">'
            f'<input type="hidden" name="action" value="{action}">')


def _form(csrf, action, fields, button):
    return ('<form method="post" action="/v1/auth/authorize" data-auth-form>' + _hidden(csrf, action)
            + fields + f'<button type="submit">{button}</button>'
            '<p class="submit-status" data-submit-status role="status" aria-live="polite" hidden></p></form>')


def _username(prefix):
    return (f'<label for="{prefix}-username">WeekGlass 账号</label><input id="{prefix}-username" '
            'name="username" autocomplete="section-weekglass username" required minlength="3" maxlength="80" '
            'spellcheck="false" autocapitalize="none">')


def _password(prefix, *, new=False):
    return (f'<label for="{prefix}-password">{"新密码" if new else "密码"}</label>'
            f'<div class="password-field"><input id="{prefix}-password" name="password" type="password" '
            f'autocomplete="section-weekglass {"new-password" if new else "current-password"}" required '
            f'{"minlength=16" if new else ""} maxlength="1024">'
            f'<button type="button" hidden data-password-toggle aria-controls="{prefix}-password" '
            'aria-pressed="false">显示</button></div>')


def _confirmation(prefix):
    return (f'<label for="{prefix}-confirm">再次输入密码</label><input id="{prefix}-confirm" '
            'name="confirm_password" type="password" autocomplete="new-password" '
            'required minlength="16" maxlength="1024">')


def page(csrf, message='', *, action='login', registration=True, recovery_key=None, expired=False,
         handoff_url=None, error_message=None):
    title = '返回 WeekGlass' if handoff_url else '连接 WeekGlass'
    head = ('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>' + title + '</title><style>' + AUTH_STYLE
            + '</style></head><body><main class="panel">' + AUTH_BRAND
            + '<h1>' + title + '</h1>')
    if handoff_url:
        content = ('<p class="handoff-success">账号验证通过。</p>'
                   '<p id="handoff-status" role="status" aria-live="polite">正在返回 WeekGlass 完成设备连接…</p>'
                   f'<a id="handoff-link" class="action-link" href="{_escape(handoff_url)}" '
                   'rel="noreferrer" referrerpolicy="no-referrer">返回 WeekGlass</a>'
                   '<p class="fine">如果没有自动返回，请点击上方按钮。请保持 WeekGlass 打开，并以应用中的连接结果为准。</p>'
                   '<p class="fine">此链接只用于本次连接，一分钟内有效。若应用已经停止等待，请回到 WeekGlass 重新发起连接。</p>'
                   '<noscript><p class="message">浏览器未启用 JavaScript，请点击“返回 WeekGlass”继续。</p></noscript>')
    elif error_message:
        content = (f'<p class="message" role="alert">{_escape(error_message)}</p>'
                   '<p>请关闭此页，回到 WeekGlass 重新连接。不会自动重新提交密码。</p>')
    elif expired:
        content = ('<p class="message" role="alert">授权页面已失效。</p>'
                   '<p>此页面可能已过期、已完成授权，或浏览器中的连接信息已变更。</p>'
                   '<p>请关闭此页，回到 WeekGlass 点击重新连接，然后在新打开的页面登录。</p>'
                   '<p class="fine">为保护账号，此页面不会自动重新提交密码。</p>')
    elif recovery_key:
        content = ('<p>请先保存你的账号恢复码。</p><p>忘记密码时，可用它重设密码。'
                   '恢复码只显示这一次，请保存在密码管理器或其他安全位置。</p>'
                   f'<code id="recovery-key">{_escape(recovery_key)}</code>'
                   + _form(csrf, 'continue', '', '我已保存，连接此设备')
                   + '<p class="fine">恢复码更新后，旧恢复码即失效。不要将它发给其他人。</p>')
    else:
        content = ('<p>让日程，在设备之间轻盈流转。</p>'
                   '<p class="fine">使用独立的 WeekGlass 账号，与主网站及学校账号分开。</p>')
        if message:
            content += f'<p class="message" role="alert">{_escape(message)}</p>'
        content += _form(csrf, 'login', _username('login') + _password('login'), '登录并连接')
        if registration:
            content += ('<details id="register"' + (' open' if action == 'register' else '')
                        + '><summary>创建 WeekGlass 账号</summary>'
                        '<p class="fine">账号使用 3–80 位英文字母、数字或 _.@+-；密码至少 16 字符。'
                        '此账号与 Viliana 主站、学校账号独立。官方云写入需订阅权益；自托管同步免费。</p>'
                        + _form(csrf, 'register', _username('register') + _password('register', new=True)
                                + _confirmation('register'), '注册并获取恢复码') + '</details>')
        content += ('<details id="recover"' + (' open' if action == 'recover' else '')
                    + '><summary>忘记密码</summary><p class="fine">使用保存的恢复码重设密码。'
                    '成功后所有旧设备退出登录，并生成新的恢复码。若没有恢复码，请联系此服务器管理员。</p>'
                    + _form(csrf, 'recover', _username('recover')
                            + '<label for="recovery-key">恢复码</label><input id="recovery-key" '
                              'name="recovery_key" autocomplete="off" required maxlength="100" spellcheck="false">'
                            + _password('recover', new=True) + _confirmation('recover'), '重设密码') + '</details>'
                    '<p class="fine">仅连接你发起授权的设备。如需取消，请返回 WeekGlass 取消登录。</p>')
    script = HANDOFF_SCRIPT if handoff_url else ('' if expired or error_message else FORM_SCRIPT)
    return (head + content + '</main>' + ('<script>' + script + '</script>' if script else '')
            + '</body></html>')
