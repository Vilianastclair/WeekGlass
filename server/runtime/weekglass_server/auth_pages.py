"""Self-contained authorization pages: no third-party assets or scripts."""
import html
import base64
import hashlib

from .auth_styles import AUTH_BRAND, AUTH_STYLE, CLOUD_SOURCE_URL, PORTAL_AUTH_STYLE


# A fixed, CSP-hashed script; no remote code or inline event handlers.
PASSWORD_SCRIPT = """document.querySelectorAll('[data-password-toggle]').forEach(function(button){button.hidden=false;button.addEventListener('click',function(){var input=document.getElementById(button.getAttribute('aria-controls'));var reveal=input.type==='password';input.type=reveal?'text':'password';button.textContent=reveal?'隐藏':'显示';button.setAttribute('aria-pressed',String(reveal));});});"""

# Progressive enhancement only: ordinary HTML form submission remains usable
# without JavaScript. Disable submit buttons, never successful input controls.
FORM_SCRIPT = PASSWORD_SCRIPT + r"""
(function(){
  var forms=Array.from(document.querySelectorAll('form[data-auth-form]'));
  var busy=false, timer=null, resendTimer=null;
  var resend=forms.find(function(form){return form.dataset && Number(form.dataset.resendAfter)>0;});
  var resendButton=resend&&resend.querySelector('button[type="submit"]');
  var resendLabel=resendButton&&resendButton.textContent;
  var resendUntil=resend?Date.now()+Number(resend.dataset.resendAfter)*1000:0;
  function updateResend(){
    if(!resendButton||busy){return;}
    if(resendTimer!==null){window.clearTimeout(resendTimer);resendTimer=null;}
    var remaining=Math.max(0,Math.ceil((resendUntil-Date.now())/1000));
    resendButton.disabled=remaining>0;
    resendButton.textContent=remaining?resendLabel+'（'+remaining+' 秒）':resendLabel;
    if(remaining){resendTimer=window.setTimeout(updateResend,1000);}
  }
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
    updateResend();
  }
  forms.forEach(function(form){
    form.addEventListener('submit',function(event){
      if(busy){event.preventDefault();return;}
      if(form.dataset && form.dataset.portalAuth==='login'){
        var hash=window.location.hash.slice(1);
        var next=new URLSearchParams(window.location.search).get('next');
        if(hash==='plans'||hash==='calendar'){next=hash;}
        if(['plans','calendar','orders','security','admin'].includes(next)){
          form.action='/account/authorize?next='+next;
        }
      }
      busy=true;form.setAttribute('aria-busy','true');
      forms.forEach(function(other){other.querySelectorAll('button[type="submit"]').forEach(function(button){
        button.dataset.readyLabel=button.textContent;button.disabled=true;
      });});
      var button=form.querySelector('button[type="submit"]');
      var action=form.querySelector('input[name="action"]').value;
      button.textContent=action.endsWith('_send')||action==='email_resend'?'正在发送…':
        action==='recover'||action==='email_reset_finish'?'正在重设密码…':
        action==='register'||action==='email_register'?'正在创建账号…':
        action==='email_pending_save'?'正在保存…':action==='email_cancel'?'正在返回…':
        action==='continue'||action==='email_manage_connect'?'正在连接…':'正在验证…';
      var status=form.querySelector('[data-submit-status]');
      status.hidden=false;status.textContent='正在安全提交，请稍候。';
      timer=window.setTimeout(function(){
        status.textContent='服务器仍未返回结果，请勿重复提交。如果长时间没有响应，请回到 WeekGlass 重新连接。';
      },15000);
    });
  });
  updateResend();
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
    var signup=target.searchParams.getAll('signup');
    if(target.protocol!=='http:'||target.hostname!=='127.0.0.1'||Number(target.port)<1024||Number(target.port)>65535||target.pathname!=='/oauth/callback'||target.username||target.password||target.hash||keys.length!==2+signup.length||signup.length>1||(signup.length&&signup[0]!=='1')||target.searchParams.getAll('code').length!==1||target.searchParams.getAll('state').length!==1||!/^[-_A-Za-z0-9]{43}$/.test(target.searchParams.get('code')||'')||!target.searchParams.get('state')){throw new Error('invalid callback');}
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

_EMAIL_PASSWORD_MIN = 8
_EMAIL_PASSWORD_MAX = 128
_EMAIL_PASSWORD_GUIDANCE = '8 至 128 个字符，至少包含字母、数字、特殊字符中的两类。空白不算特殊字符。'


def _escape(value):
    return html.escape(value, quote=True)


def _hidden(csrf, action):
    return (f'<input type="hidden" name="csrf" value="{_escape(csrf)}">'
            f'<input type="hidden" name="action" value="{action}">')


def _form(csrf, action, fields, button, *, secondary=False, resend_after=0, portal=False):
    style = ' class="secondary-form"' if secondary else ''
    countdown = f' data-resend-after="{resend_after:d}"' if resend_after and resend_after > 0 else ''
    target = '/account/authorize' if portal else '/v1/auth/authorize'
    portal_login = ' data-portal-auth="login"' if portal and action == 'login' else ''
    return (f'<form method="post" action="{target}" data-auth-form{style}{countdown}{portal_login}>' + _hidden(csrf, action)
            + fields + f'<button type="submit">{_escape(button)}</button>'
            '<p class="submit-status" data-submit-status role="status" aria-live="polite" hidden></p></form>')


def _username(prefix, *, or_email=False):
    label = 'WeekGlass 账号或邮箱' if or_email else 'WeekGlass 账号'
    return (f'<label for="{prefix}-username">{label}</label><input id="{prefix}-username" '
            f'name="username" autocomplete="section-weekglass username" required minlength="3" maxlength="{254 if or_email else 80}" '
            'spellcheck="false" autocapitalize="none">')


def _email(prefix, *, label='邮箱', login=False, value=None):
    prefill = f' value="{_escape(value)}"' if value is not None else ''
    return (f'<label for="{prefix}-email">{label}</label><input id="{prefix}-email" '
            f'name="email" type="email" autocomplete="section-{prefix} {"username" if login else "email"}" '
            f'required maxlength="254" spellcheck="false" autocapitalize="none"{prefill}>')


def _password(prefix, *, new=False, label=None, section='weekglass', min_length=16, max_length=1024, guidance=None):
    requirements = f'minlength="{min_length}" aria-describedby="{prefix}-password-help" ' if new else ''
    guidance = guidance or f'至少 {min_length} 个字符'
    return (f'<label for="{prefix}-password">{label or ("新密码" if new else "密码")}</label>'
            f'<div class="password-field"><input id="{prefix}-password" name="password" type="password" '
            f'autocomplete="section-{section} {"new-password" if new else "current-password"}" required '
            f'{requirements}maxlength="{max_length}">'
            f'<button type="button" hidden data-password-toggle aria-controls="{prefix}-password" '
            'aria-pressed="false">显示</button></div>'
            + (f'<p class="field-help" id="{prefix}-password-help">{_escape(guidance)}</p>' if new else ''))


def _confirmation(prefix, *, section='weekglass', min_length=16, max_length=1024):
    return (f'<label for="{prefix}-confirm">再次输入密码</label><input id="{prefix}-confirm" '
            f'name="confirm_password" type="password" autocomplete="section-{section} new-password" '
            f'required minlength="{min_length}" maxlength="{max_length}">')


def _code(prefix):
    return (f'<label for="{prefix}-code">验证码</label><input id="{prefix}-code" class="otp-code" '
            'name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" '
            'pattern="[0-9]{6}" required spellcheck="false">')


def _feedback(message, notice):
    error = f'<p class="message" role="alert">{_escape(message)}</p>' if message else ''
    status = f'<p class="notice" role="status">{_escape(notice)}</p>' if notice else ''
    return error + status


def _link(target, label, *, current=False):
    marked = ' aria-current="page"' if current else ''
    return f'<a href="#{target}"{marked}>{label}</a>'


def _nav(label, links, *, style='links'):
    return f'<nav class="{style}" aria-label="{label}">' + ''.join(links) + '</nav>'


def _primary_nav(view, registration):
    if not registration:
        return ''
    return _nav('账号入口', [_link('login', '登录', current=view != 'register'),
                            _link('register', '注册', current=view == 'register')], style='segment')


def _recovery_fields(*, or_email):
    minimum = _EMAIL_PASSWORD_MIN if or_email else 16
    guidance = f'邮箱注册账号：{_EMAIL_PASSWORD_GUIDANCE}原账号：至少 16 个字符。' if or_email else None
    return (_username('recover', or_email=or_email) + '<label for="recovery-key">恢复码</label><input id="recovery-key" '
            'name="recovery_key" autocomplete="off" required maxlength="100" spellcheck="false">'
            + _password('recover', new=True, min_length=minimum, guidance=guidance)
            + _confirmation('recover', min_length=minimum))


def _management_fields(*, portal_bound=False):
    if portal_bound:
        handle = '<input type="hidden" name="identity_kind" value="session"><input type="hidden" name="identifier" value="">'
    else:
        handle = ('<input type="hidden" name="identity_kind" value="unified">'
                  '<label for="manage-identifier">账号或邮箱</label><input id="manage-identifier" name="identifier" '
                  'required maxlength="254" autocomplete="section-manage username" spellcheck="false" autocapitalize="none">')
    return handle + _password('manage', section='manage', label='当前密码')


# Local fragment navigation keeps the same browser authorization grant and also
# works when JavaScript is disabled. Only one pane is visible or keyboard reachable.
def _entry_views(csrf, action, registration, email_enabled, email_login_enabled, email_signup_enabled,
                 email_manage_enabled, message, notice):
    routes = {'login': 'login', 'email_login': 'login', 'legacy_login': 'login',
              'email_pending_login': 'login', 'register': 'register', 'email_register': 'register', 'email_otp_send': 'login',
              'email_reset_send': 'reset', 'recover': 'recover', 'email_manage_begin': 'manage'}
    current = routes.get(action, 'login')
    if current == 'register' and not registration:
        current = 'login'

    def pane(view, content, *, nav='', intro=''):
        active = ' class="is-current"' if view == current else ''
        feedback = _feedback(message, notice) if view == current else ''
        return (f'<section id="{view}"{active} tabindex="-1">'
                + _primary_nav(view, registration) + nav + intro + feedback + content + '</section>')

    def account_links():
        recovery = 'reset' if email_enabled else 'recover'
        links = [_link(recovery, '忘记密码')]
        if email_manage_enabled:
            links.append(_link('manage', '验证或更换邮箱'))
        return _nav('更多账号选项', links)

    panes = [pane('login', _form(csrf, 'login', _username('login', or_email=email_login_enabled)
                               + _password('login'), '登录并连接') + account_links())]

    if email_enabled:
        panes += [
            pane('reset', _form(csrf, 'email_reset_send', _email('reset'), '发送验证码')
                 + _nav('其他恢复选项', [_link('recover', '使用恢复码'), _link('login', '返回登录')]),
                 intro='<h2>找回密码</h2><p class="view-copy">已付费并验证邮箱的用户可通过验证码设置新密码。</p>'),
        ]
    if email_manage_enabled:
        panes.append(pane('manage', _form(csrf, 'email_manage_begin', _management_fields(), '确认身份')
                          + _nav('返回登录', [_link('login', '返回登录')]),
                          intro='<h2>验证或更换邮箱</h2><p class="view-copy">已付费用户可验证当前邮箱，也可以改用另一个邮箱。请先确认账号和密码。</p>'))

    if registration:
        # Hosted email sign-up and self-hosted username sign-up share the same
        # visible entry point but keep distinct server-side contracts.
        if email_signup_enabled:
            fields = _email('register', login=True)
            intro = '<p class="view-copy">注册即连接设备。付款确认后可验证邮箱。</p>'
            submit_action, label = 'email_register', '注册并连接'
            password_rules = dict(section='register', min_length=_EMAIL_PASSWORD_MIN, max_length=_EMAIL_PASSWORD_MAX)
            password_guidance = _EMAIL_PASSWORD_GUIDANCE
        else:
            fields = _username('register')
            intro = '<p class="view-copy">账号使用 3 到 80 位英文字母、数字或 _.@+-。</p>'
            submit_action, label = 'register', '注册并获取恢复码'
            password_rules = {}
            password_guidance = None
        panes.append(pane('register', _form(csrf, submit_action, fields
                          + _password('register', new=True, label='密码', guidance=password_guidance, **password_rules)
                          + _confirmation('register', **password_rules), label)
                          + ('<p class="field-help">官方云同步需开通权益；本地日历仍可免费使用。</p>'
                             if email_signup_enabled else ''), intro=intro))

    recovery_intro = '<h2>使用恢复码重设密码</h2><p class="view-copy">成功后，旧设备会退出登录，并生成新的恢复码。'
    if email_login_enabled:
        recovery_intro += '原账号会解除邮箱绑定；用邮箱注册的账号会保留邮箱。'
    panes.append(pane('recover', _form(csrf, 'recover', _recovery_fields(or_email=email_login_enabled), '重设密码')
                      + _nav('其他恢复选项', ([_link('reset', '使用邮箱找回')] if email_enabled else [])
                             + [_link('login', '返回登录')])
                      + '<p class="field-help">如果没有可用的恢复码，请联系服务器管理员。</p>',
                      intro=recovery_intro + '</p>'))
    return '<div class="auth-views">' + ''.join(panes) + '</div>'


def _portal_entry(csrf, action, *, registration, email_enabled, email_signup_enabled, message, notice):
    feedback = _feedback(message, notice)
    back = '<div class="portal-links"><a href="/account/login">返回登录</a></div>'
    if action == 'email_register' and registration and email_signup_enabled:
        rules = dict(section='register', min_length=_EMAIL_PASSWORD_MIN, max_length=_EMAIL_PASSWORD_MAX)
        fields = _email('register', login=True) + _password('register', new=True, label='密码',
                  guidance=_EMAIL_PASSWORD_GUIDANCE, **rules) + _confirmation('register', **rules)
        return ('<p class="portal-intro">用邮箱和密码即可创建账号。开通云同步后，再验证邮箱。</p>' + feedback
                + _form(csrf, 'email_register', fields, '创建账号', portal=True)
                + '<p class="field-help quiet">注册即表示同意<a href="/terms">服务条款</a>和<a href="/privacy">隐私说明</a>。</p>'
                + '<div class="portal-links"><span>已有账号？</span> <a href="/account/login">立即登录</a></div>')
    if action == 'register' and registration and not email_signup_enabled:
        return ('<p class="portal-intro">请选择 3 至 80 位英文字母、数字或 _.@+- 作为账号。</p>' + feedback
                + _form(csrf, 'register', _username('register') + _password('register', new=True, label='密码')
                  + _confirmation('register'), '创建账号', portal=True) + back)
    if action == 'recover':
        return ('<p class="portal-intro">输入账号及已保存的恢复码。重设密码后，原有会话会退出。</p>' + feedback
                + _form(csrf, 'recover', _recovery_fields(or_email=True), '重设密码', portal=True)
                + ('<div class="portal-links"><a href="/account/recover/email">用已验证的邮箱找回</a></div>' if email_enabled else '')
                + back)
    if action == 'email_reset_send' and email_enabled:
        return ('<p class="portal-intro">请输入已验证的邮箱。收到验证码后，可设置新密码。</p>' + feedback
                + _form(csrf, 'email_reset_send', _email('reset'), '发送验证码', portal=True)
                + '<div class="portal-links"><a href="/account/recover">使用恢复码</a></div>' + back)
    return ('<p class="portal-intro">使用 WeekGlass 账号或注册邮箱登录。未验证的邮箱也可用密码登录。</p>' + feedback
            + _form(csrf, 'login', _username('login', or_email=True) + _password('login'), '登录', portal=True)
            + '<div class="portal-links"><a href="/account/recover">忘记密码</a>'
            + ('<a href="/account/register">创建账号</a>' if registration else '') + '</div>')


# State in these views is tied to the server grant. The only displayed address
# comes from the server's pre-masked hint; resend and cancel post no credentials.
_CODE_VIEWS = {
    'email_otp_verify': ('输入验证码', '验证后连接此设备', '验证并连接'),
    'email_reset_verify': ('验证邮箱', '验证后设置新密码', '验证验证码'),
    'email_bind_verify': ('验证邮箱', '验证后可用此邮箱登录和找回密码', '验证并连接'),
    'email_change_old_verify': ('验证原邮箱', '验证后输入新邮箱', '验证原邮箱'),
    'email_change_new_verify': ('验证新邮箱', '更换后所有旧设备将退出登录', '确认更换'),
}

_STEP_TITLES = {
    'email_reset_finish': '设置新密码',
    'email_change_old_send': '验证原邮箱',
    'email_change_new_send': '输入新邮箱',
} | {action: info[0] for action, info in _CODE_VIEWS.items()}


def _email_step(csrf, action, email_hint, feedback, resend_after, *, management_only=False, portal=False):
    recipient = f' <span class="email-hint">{_escape(email_hint)}</span> ' if email_hint else '邮箱'
    if action in _CODE_VIEWS:
        _, next_step, label = _CODE_VIEWS[action]
        if action == 'email_bind_verify' and management_only:
            label = '确认验证'
        intro = f'<p>请输入发往{recipient}的 6 位验证码。{next_step}。</p>'
        fields = _code('verify')
        resend = ('<p class="field-help resend-help">没收到邮件？请检查垃圾邮件。</p>'
                  + _form(csrf, 'email_resend', '', '重新发送', secondary=True, resend_after=resend_after, portal=portal))
    else:
        resend = ''
        label = '发送验证码'
        if action == 'email_reset_finish':
            intro = '<p>重设密码后，所有设备会退出，已保存的恢复码也会失效。请用新密码登录。</p>'
            password_rules = dict(section='reset-finish', min_length=_EMAIL_PASSWORD_MIN, max_length=_EMAIL_PASSWORD_MAX)
            fields = (_password('reset-finish', new=True, guidance=_EMAIL_PASSWORD_GUIDANCE, **password_rules)
                      + _confirmation('reset-finish', **password_rules))
            label = '保存新密码'
        elif action == 'email_change_old_send':
            intro = f'<p>先向{recipient if email_hint else "原邮箱"}发送验证码，确认后再验证新邮箱。</p>'
            fields = ''
        else:
            intro = '<p>请填写新邮箱。更换成功后，所有旧设备将退出登录。</p>'
            fields = _email('change', label='新邮箱')
    controls = '<div class="step-controls">' + resend + _management_cancel(csrf, management_only, portal) + '</div>'
    return intro + feedback + _form(csrf, action, fields, label, portal=portal) + controls


def _management_cancel(csrf, management_only, portal=False):
    if portal:
        label, href = ('返回安全设置', '/account/security') if management_only else ('取消并返回登录', '/account/login')
        return f'<a class="step-return" href="{href}">{label}</a>'
    label = '返回验证入口' if management_only else '取消并返回登录'
    return _form(csrf, 'email_cancel', '', label, secondary=True)


def _management_title(action, email_paid, email_enabled):
    if action == 'email_manage_unavailable':
        return '暂时无法管理邮箱'
    return '验证邮箱' if email_paid and email_enabled else '邮箱尚未验证'


def _management_step(csrf, action, pending_email, email_paid, email_enabled, feedback, *,
                     email_pending_editable=False, management_only=False, backup_username=None, portal=False):
    if action == 'email_manage_unverified' and email_paid and email_enabled:
        advice = ('确认当前邮箱，或填写新的邮箱地址。验证后可用它登录和找回密码。' if pending_email else
                  '填写你要验证的邮箱。验证后可用它登录和找回密码。')
        form = _form(csrf, 'email_bind_send', _email('bind', value=pending_email), '发送验证码', portal=portal)
    else:
        if email_paid:
            advice = '邮件服务暂不可用。你仍可使用密码登录。'
        else:
            advice = '付款确认后可验证或更换邮箱。你仍可使用密码登录。'
        form = ''
        if action == 'email_manage_unverified' and email_pending_editable:
            form = ('<h2>更正注册邮箱</h2><p class="view-copy">如果注册时填错邮箱，可以先更正。此操作不会发送邮件。</p>'
                    + _form(csrf, 'email_pending_save', _email('pending', value=pending_email)
                            + _password('pending', section='pending'), '保存邮箱', portal=portal))
    secondary = _management_cancel(csrf, management_only, portal)
    if not management_only:
        if form:
            secondary = _form(csrf, 'email_manage_connect', '', '跳过并连接', secondary=True) + secondary
        else:
            form = _form(csrf, 'email_manage_connect', '', '继续连接')
    backup = ''
    if action == 'email_manage_unverified' and backup_username:
        backup = ('<div class="account-fallback"><p>邮箱无法登录时，可使用此账号标识。</p>'
                  f'<code aria-label="备用账号标识">{_escape(backup_username)}</code></div>')
    return f'<p>{advice}</p>' + feedback + form + '<div class="step-controls">' + secondary + '</div>' + backup


_AUTH_ART = '''<aside class="auth-art" aria-hidden="true">
  <div class="art-caption"><span class="art-dot"></span> WEEKGLASS CLOUD</div>
  <div class="art-calendar">
    <div class="art-grid"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
    <i class="art-event event-one"></i><i class="art-event event-two"></i>
    <i class="art-event event-three"></i><i class="art-event event-four"></i>
    <div class="art-signal"><i></i> 同步就绪</div>
  </div>
  <div class="art-copy"><p>让日程随行</p><span>在不同设备上，接着安排同一周。</span></div>
</aside>'''


def page(csrf, message='', *, action='login', registration=True, recovery_key=None, expired=False,
         handoff_url=None, error_message=None, email_enabled=False, email_hint=None, notice=None, resend_after=0,
         email_login_enabled=False, email_signup_enabled=False, email_manage_enabled=False,
         pending_email=None, email_paid=False, email_pending_editable=False, management_only=False,
         management_done=False, backup_username=None, portal=False, portal_bound=False):
    active = not (recovery_key or expired or error_message or handoff_url)
    step = active and email_enabled and action in _STEP_TITLES
    management = active and action in ('email_manage_unverified', 'email_manage_unavailable')
    if handoff_url:
        title = '返回 WeekGlass'
    elif step:
        title = _STEP_TITLES[action]
    elif management:
        title = _management_title(action, email_paid, email_enabled)
    elif management_done:
        title = '邮箱设置' if portal else '邮箱已验证'
    elif management_only:
        title = '验证或更换邮箱'
    elif portal:
        title = ('保存恢复码' if recovery_key else '找回密码' if action in ('recover', 'email_reset_send') else
                 '创建 WeekGlass 账号' if action in ('register', 'email_register') and registration else '登录 WeekGlass')
    else:
        title = '连接 WeekGlass'
    panel_head = AUTH_BRAND + ('<p class="auth-eyebrow">账号控制台</p>' if portal else '') + '<h1>' + title + '</h1>'
    main_open = ('<main class="auth-stage">' + _AUTH_ART + '<section class="panel auth-panel">' if portal else
                 '<main class="panel">')
    head = ('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>' + title + '</title><style>' + AUTH_STYLE + (PORTAL_AUTH_STYLE if portal else '')
            + '</style></head><body' + (' class="portal-auth"' if portal else '') + '>' + main_open + panel_head)
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
                   + ('<a class="action-link" href="/account">返回账号控制台</a>' if portal else
                      '<p>请关闭此页，回到 WeekGlass 重新连接。不会自动重新提交密码。</p>'))
    elif expired:
        content = ('<p class="message" role="alert">授权页面已失效。</p>'
                   '<p>此页面可能已过期、已完成授权，或浏览器中的连接信息已变更。</p>'
                   + ('<a class="action-link" href="/account">返回账号控制台</a>' if portal else
                      '<p>请关闭此页，回到 WeekGlass 点击重新连接，然后在新打开的页面登录。</p>'))
    elif recovery_key:
        content = ('<p>请先保存你的账号恢复码。</p><p>忘记密码时，可用它重设密码。'
                   '恢复码只显示这一次，请保存在密码管理器或其他安全位置。</p>'
                   f'<code id="recovery-key">{_escape(recovery_key)}</code>'
                   + _form(csrf, 'continue', '', '我已保存，进入控制台' if portal else '我已保存，连接此设备', portal=portal)
                   + '<p class="fine">恢复码更新后，旧恢复码即失效。不要将它发给其他人。</p>')
    elif step:
        content = _email_step(csrf, action, email_hint, _feedback(message, notice), resend_after,
                              management_only=management_only, portal=portal)
    elif management:
        content = _management_step(csrf, action, pending_email, email_paid, email_enabled, _feedback(message, notice),
                                   email_pending_editable=email_pending_editable, management_only=management_only,
                                   backup_username=backup_username, portal=portal)
    elif management_done:
        content = _feedback(message, notice) + ('<a class="action-link" href="/account/security">返回安全设置</a>' if portal else
                                                '<p>回到 WeekGlass，在账号设置中查看邮箱验证结果。</p>')
    elif management_only:
        content = ('<p>请先确认身份。付款确认后，即可验证当前邮箱或更换邮箱。</p>' + _feedback(message, notice)
                   + _form(csrf, 'email_manage_begin', _management_fields(portal_bound=portal_bound), '确认身份', portal=portal)
                   + ('<p class="portal-links"><a href="/account/security">返回安全设置</a></p>' if portal else ''))
    elif portal:
        content = (_portal_entry(csrf, action, registration=registration, email_enabled=email_enabled,
                                 email_signup_enabled=email_signup_enabled, message=message, notice=notice)
                   + '<p class="connection-note">使用独立的 WeekGlass 账号，与 Viliana 主站及学校账号分开。'
                     f'<br><a href="{CLOUD_SOURCE_URL}">服务端源代码</a></p>')
    else:
        email_password = email_signup_enabled or email_login_enabled or email_enabled
        content = ('<p class="scope">使用独立的 WeekGlass 账号，与主网站及学校账号分开。</p>'
                   + _entry_views(csrf, action, registration, email_enabled, email_password,
                                  email_signup_enabled, email_manage_enabled, message, notice)
                   + '<p class="connection-note">仅连接你发起授权的设备。</p>')
    script = HANDOFF_SCRIPT if handoff_url else ('' if expired or error_message or management_done else FORM_SCRIPT)
    return (head + content + ('</section>' if portal else '') + '</main>' + ('<script>' + script + '</script>' if script else '')
            + '</body></html>')
