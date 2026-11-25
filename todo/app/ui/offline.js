// The shell passes the words in the fragment; they are shown as plain text.
function show() {
  const params = new URLSearchParams(location.hash.slice(1));
  document.documentElement.lang = params.get('lang') || 'en';
  for (const id of ['title', 'reason', 'hint']) document.getElementById(id).textContent = params.get(id) || '';
}
addEventListener('hashchange', show);
show();
