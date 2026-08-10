// =====================================================================
// EDIT THESE TWO VALUES for your Supabase project
// (Project Settings > API > Project URL / anon public key)
// =====================================================================
const SUPABASE_URL = 'https://dmhzhncoulmeaeicljpl.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRtaHpobmNvdWxtZWFlaWNsanBsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyNjk3NjAsImV4cCI6MjEwMTg0NTc2MH0.YTYiA4_cmrIqaCVU_Mb0kBuT9Ox4acFJQZEWYKPSdAs';

if (typeof supabase === 'undefined') {
  document.write('<div style="font-family:sans-serif;background:#3a0d12;color:#fff;padding:16px 22px;">' +
    '<b>Supabase library failed to load from both jsdelivr and unpkg.</b> Check your internet connection, ' +
    'ad-blocker, or firewall — this page cannot function without it.' +
    '</div>');
  throw new Error('supabase-js UMD bundle not loaded from either CDN — see message above');
}

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------

// Persistent per-browser random id (used for team device binding and
// audience vote de-duplication). Survives refresh, not shared across devices.
function getDeviceId() {
  let id = localStorage.getItem('vsd_device_id');
  if (!id) {
    id = 'dev_' + crypto.randomUUID();
    localStorage.setItem('vsd_device_id', id);
  }
  return id;
}

function toast(msg, ms = 2600) {
  let el = document.getElementById('__toast');
  if (!el) {
    el = document.createElement('div');
    el.id = '__toast';
    el.className = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.display = 'block';
  clearTimeout(el._t);
  el._t = setTimeout(() => (el.style.display = 'none'), ms);
}

// Formats a Date/ISO timer_end into whole seconds remaining (>=0)
function secondsRemaining(timerEndIso) {
  if (!timerEndIso) return 0;
  const ms = new Date(timerEndIso).getTime() - Date.now();
  return Math.max(0, Math.ceil(ms / 1000));
}

// Fetch the single event currently marked LIVE (falls back to most recent)
async function getActiveEvent() {
  let { data } = await sb.from('quiz_events').select('*').eq('status', 'LIVE').limit(1).single();
  if (!data) {
    const res = await sb.from('quiz_events').select('*').order('created_at', { ascending: false }).limit(1).single();
    data = res.data;
  }
  return data;
}

async function getSessionForEvent(eventId) {
  const { data } = await sb.from('quiz_session').select('*').eq('event_id', eventId).single();
  return data;
}
