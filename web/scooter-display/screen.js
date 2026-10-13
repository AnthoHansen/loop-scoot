'use strict';
const TEXT = {
  en: { off:'OUT OF SERVICE', service:'COLLECTION', busy:'PREPARING', locked:'LOCKED', empty:'BATTERY EMPTY',
        low:'LOW BATTERY', riding:'RIDING', ready:'READY', shut:'LOCKED', open:'OPEN', link:'LINKING' },
  fr: { off:'HORS SERVICE', service:'COLLECTE', busy:'PRÉPARATION', locked:'VERROUILLÉE', empty:'BATTERIE VIDE',
        low:'BATTERIE FAIBLE', riding:'CONDUITE', ready:'PRÊTE', shut:'FERMÉ', open:'OUVERT', link:'CONNEXION' }
};
let words = TEXT.en;
const elements = Object.fromEntries(['speed','status','battery','charge','lock','light'].map(id => [id, document.getElementById(id)]));
let lastUpdate = 0;
function render(data) {
  if (!data || data.type !== 'telemetry') return;
  lastUpdate = performance.now();
  words = TEXT[data.language] || TEXT.en;
  document.documentElement.lang = data.language === 'fr' ? 'fr' : 'en';
  elements.speed.textContent = Number.isFinite(data.speed) ? Math.round(Math.max(0, data.speed)).toString() : '—';
  const available = data.batteryAvailable === true && Number.isFinite(data.battery) && data.battery >= 0 && data.battery <= 100;
  elements.battery.textContent = available ? `${Math.round(data.battery)}%` : '—';
  elements.charge.style.width = available ? `${data.battery}%` : '0%';
  elements.charge.style.background = available && data.battery <= 20 ? '#ffc36b' : '#48e1c1';
  const warning = data.damaged || data.locked || (available && data.battery <= 10);
  elements.status.textContent = data.damaged ? words.off : data.service ? words.service : data.busy ? words.busy : data.locked ? words.locked : available && data.battery === 0 ? words.empty : available && data.battery <= 10 ? words.low : data.riding ? words.riding : words.ready;
  elements.status.classList.toggle('warn', !!warning);
  elements.lock.textContent = data.locked ? words.shut : words.open;
  elements.lock.classList.toggle('locked', !!data.locked);
  elements.light.classList.toggle('on', !!data.headlight);
}
window.addEventListener('message', event => render(event.data));
setInterval(() => {
  if (!lastUpdate || performance.now() - lastUpdate <= 2500) return;
  elements.speed.textContent = '—'; elements.battery.textContent = '—';
  elements.charge.style.width = '0%'; elements.status.textContent = words.link;
  elements.status.classList.remove('warn'); elements.lock.textContent = '—';
  elements.light.classList.remove('on');
}, 500);
