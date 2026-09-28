// Basic consent mode: do not contact Google until the visitor opts in.
(() => {
  'use strict';
  const id = 'G-F0JJ994ZBP';
  const key = 'transcripts.analytics.v1';
  const lifetime = 180 * 24 * 60 * 60 * 1000;
  const panel = document.getElementById('analytics-choice');
  const settings = document.getElementById('analytics-settings');
  const allow = document.getElementById('analytics-allow');
  const decline = document.getElementById('analytics-decline');
  const optedOut = navigator.globalPrivacyControl === true;
  let enabled = false;
  let choice = null;
  try {
    const saved = JSON.parse(localStorage.getItem(key));
    if (saved && Date.now() - saved.time < lifetime && ['granted', 'denied'].includes(saved.value)) choice = saved.value;
  } catch (_) { /* Storage can be unavailable in private browsers. */ }
  function clearCookies() {
    for (const name of ['_ga', '_ga_' + id.slice(2).replaceAll('-', '_')]) {
      for (const domain of ['', '; domain=' + location.hostname, '; domain=.' + location.hostname]) {
        document.cookie = name + '=; Max-Age=0; path=/' + domain + '; SameSite=Lax; Secure';
      }
    }
  }
  function start() {
    if (enabled || optedOut || !['transcripts.doughatcher.com', 'transcripts.hatcher.ltd'].includes(location.hostname)) return;
    enabled = true;
    window['ga-disable-' + id] = false;
    window.dataLayer = window.dataLayer || [];
    window.gtag = function () { window.dataLayer.push(arguments); };
    const denied = {analytics_storage:'denied', ad_storage:'denied', ad_user_data:'denied', ad_personalization:'denied'};
    window.gtag('consent', 'default', denied);
    window.gtag('consent', 'update', {...denied, analytics_storage:'granted'});
    window.gtag('js', new Date());
    let referrer = '';
    try { referrer = new URL(document.referrer).origin; } catch (_) {}
    window.gtag('config', id, {
      send_page_view: false,
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
      cookie_domain: 'none',
      cookie_expires: 90 * 24 * 60 * 60,
      cookie_flags: 'SameSite=Lax;Secure',
      page_location: location.origin + location.pathname,
      page_referrer: referrer
    });
    window.gtag('event', 'page_view', {page_title:document.title});
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtag/js?id=' + id;
    document.head.appendChild(script);
  }
  function stop() {
    window['ga-disable-' + id] = true;
    if (window.gtag) window.gtag('consent', 'update', {analytics_storage:'denied',ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied'});
    clearCookies();
  }
  function save(value) {
    choice = value;
    try { localStorage.setItem(key, JSON.stringify({value, time:Date.now()})); } catch (_) {}
    panel.hidden = true;
    if (value === 'granted') start();
    else {
      stop();
      // Unload the tag and all of its handlers when withdrawing consent.
      if (enabled) location.reload();
    }
    settings.focus();
  }
  settings.hidden = false;
  settings.addEventListener('click', () => { panel.hidden = false; (optedOut ? decline : allow).focus(); });
  allow.addEventListener('click', () => save('granted'));
  decline.addEventListener('click', () => save('denied'));
  if (optedOut) {
    allow.disabled = true;
    document.getElementById('analytics-browser-choice').hidden = false;
    stop();
  } else if (choice === 'granted') start();
  else {
    stop();
    if (choice === null) panel.hidden = false;
  }
  document.addEventListener('click', event => {
    if (!enabled || choice !== 'granted' || optedOut) return;
    const link = event.target.closest('a');
    if (!link) return;
    const url = new URL(link.href, location.href);
    let destination;
    if (url.hostname === 'apps.apple.com' && url.pathname.includes('6802331047')) destination = url.searchParams.get('platform') === 'mac' ? 'mac_app_store' : url.searchParams.get('platform') === 'iphone' ? 'ios_app_store' : 'app_store';
    else if (url.origin === location.origin && /\/Transcripts-[^/]+\.(dmg|zip)$/.test(url.pathname)) destination = 'mac_direct';
    if (destination) window.gtag('event', 'download_click', {destination});
  });
})();
