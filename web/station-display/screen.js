(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const CLEAR = { en:'Keep the area clear', fr:'Gardez la zone libre' };
  const WAIT = { en:'Wait before getting on', fr:'Patientez avant de monter' };
  const PH = {
    preparing:[['PREPARING','PRÉPARATION'],['Preparing','Préparation'],0],
    rising:[['DISPENSING','DISTRIBUTION'],['Opening the station','Ouverture de la borne'],0],
    raised:[['DISPENSING','DISTRIBUTION'],['Station open','Borne ouverte'],0],
    opening:[['DISPENSING','DISTRIBUTION'],['Opening the bay','Ouverture du compartiment'],0],
    extracting:[['DISPENSING','DISTRIBUTION'],['Coming out','Sortie en cours'],0],
    presenting:[['DISPENSING','DISTRIBUTION'],['Handing over','Mise à disposition'],1],
    lowering:[['DISPENSING','DISTRIBUTION'],['Setting down','Pose au sol'],1],
    presented:[['DISPENSING','DISTRIBUTION'],['Unlocking','Déverrouillage'],1],
    arm_return:[['DISPENSING','DISTRIBUTION'],['Releasing the grip','Libération de la prise'],1],
    released:[['READY','PRÊTE'],['Scooter released','Trottinette libérée'],
              ['Your ride can start','Votre trajet peut commencer']],
    closing:[['CLOSING','FERMETURE'],['Closing the bay','Fermeture du compartiment'],0],
    waiting:[['CLOSING','FERMETURE'],['End of cycle','Fin du cycle'],0],
    retracting:[['CLOSING','FERMETURE'],['Retracting the station','Rentrée de la borne'],0],
    cooling:[['CLOSING','FERMETURE'],['End of cycle','Fin du cycle'],0]
  };
  const FREE = [['AVAILABLE','DISPONIBLE'],['At your service','À votre disposition'],
                ['Book it in the SCOOT app','Réservez dans l’app SCOOT']];
  const NONE = [['UNAVAILABLE','INDISPONIBLE'],['No scooter','Aucune trottinette'],
                ['Try another station','Consultez les autres bornes']];
  const LINK = [['LINKING','CONNEXION'],['Syncing','Synchronisation'],['Please wait','Veuillez patienter']];
  const NOUN = { en:['scooter','scooters'], fr:['trottinette','trottinettes'] };
  const TITLE = { en:'SCOOT station', fr:'Borne SCOOT' };
  const FOOT = { en:'AVAILABLE', fr:'DISPONIBLES' };
  const LINKING = { en:'LINKING TO THE STATION', fr:'CONNEXION À LA BORNE' };
  const MINE = { en:'Your rental', fr:'Votre location' };
  const LEFT = { en:' min left', fr:' min restantes' };
  const RANGE = { en:' km range', fr:' km d’autonomie' };
  const n = v => Number.isFinite(v) ? Math.max(0, Math.floor(v)) : null;
  function offer(d) {
    const parts = [];
    if (n(d.durationMin)) parts.push(n(d.durationMin) + ' MIN');
    if (n(d.rangeKm)) parts.push(n(d.rangeKm) + ' KM');
    return parts.length ? ' · ' + parts.join(' · ') : '';
  }
  function pick(row, i) {
    var value = row[i];
    if (value === 0) return CLEAR;
    if (value === 1) return WAIT;
    return { en: value[0], fr: value[1] };
  }
  window.addEventListener('message', event => {
    const d=event.data;
    if (!d || d.type!=='station') return;
    const lang = d.language === 'fr' ? 'fr' : 'en';
    const known=d.known===true && Number.isFinite(d.available);
    const count=known?Math.max(0,Math.floor(d.available)):null;
    const busy=d.phase && d.phase!=='idle';
    const row=known?(busy?(PH[d.phase]||PH.preparing):count>0?FREE:NONE):LINK;
    $('count').textContent=count===null?'—':String(count);
    $('noun').textContent=NOUN[lang][count===1?0:1];
    $('label').textContent=typeof d.label==='string'?d.label:TITLE[lang];
    $('state').textContent=pick(row,0)[lang];
    $('operation').textContent=pick(row,1)[lang];
    $('hint').textContent=pick(row,2)[lang];
    const left=n(d.rentalLeftMin);
    if (!busy && left!==null) {
      const km=n(d.rentalRangeKm);
      $('operation').textContent=MINE[lang];
      $('hint').textContent=left+LEFT[lang]+(km!==null?' · '+km+RANGE[lang]:'');
    }
    document.documentElement.lang=lang;
    document.body.dataset.status=busy?'busy':count===0?'empty':'ready';
    $('progress').style.width=(busy?Math.max(0,Math.min(1,Number(d.progress)||0))*100:count>0?100:0)+'%';
    $('footer').textContent=known?(count+' / '+(Number.isFinite(d.capacity)?d.capacity:'—')+' '+FOOT[lang]+offer(d)):LINKING[lang];
  });
})();
