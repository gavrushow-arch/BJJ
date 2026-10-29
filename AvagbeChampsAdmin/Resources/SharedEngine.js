/* BJJ tournament rules. No Google/Telegram dependencies in this file. */
var BJJ = (function () {
  'use strict';
  function fail(message) { throw new Error(message); }
  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function empty() { return {schema:2, revision:0, next:1, events:[], participants:[], groups:[], matches:[], clubs:[], categoryConfigs:[], mats:[], scheduleDraft:[], schedulePublished:[], devices:[], challenges:[], operations:[], changes:[], sessions:{}, processed:{}, outbox:[]}; }
  function id(db, prefix) { return prefix + (db.next++).toString(36); }
  function active(db) { return db.events.find(function(e){return e.status !== 'Архив';}) || null; }
  function byId(list, key) { return list.find(function(x){return x.id === key;}); }
  function roster(db, event) { return db.participants.filter(function(p){return p.eventId === event.id && p.status === 'Зарегистрирован';}); }
  function editable(db, eventId) {
    var e = active(db);
    if (!e || e.id !== eventId || e.status !== 'Регистрация') fail('Регистрация закрыта или соревнование изменилось.');
    return e;
  }
  function createEvent(db, title, date, system, belts) {
    if (active(db)) fail('Сначала завершите и архивируйте активное соревнование.');
    title = String(title || '').trim();
    if (title.length < 2 || title.length > 100) fail('Название: от 2 до 100 символов.');
    if (['Олимпийская','Круговая'].indexOf(system) < 0) fail('Неизвестная система.');
    if(date){var parts=/^(\d{2})\.(\d{2})\.(\d{4})$/.exec(date);if(!parts)fail('Нужна дата ДД.ММ.ГГГГ.');var check=new Date(Date.UTC(+parts[3],+parts[2]-1,+parts[1]));if(check.getUTCFullYear()!==+parts[3]||check.getUTCMonth()!==+parts[2]-1||check.getUTCDate()!==+parts[1])fail('Такой даты не существует.');}
    var event = {id:id(db,'e'),title:title,date:date,system:system,belts:!!belts,status:'Регистрация',version:1,mergeBelts:[],mergeWeights:{},ties:{}};
    db.events.push(event); return event;
  }
  function validatePerson(data, event, categories) {
    var name = String(data.name || '').trim().replace(/\s+/g,' ');
    if (name.length < 3 || name.length > 150 || name.split(' ').length < 2 || /[\r\n\x00-\x1f]/.test(name)) fail('Введите ФИО, минимум два слова, не более 150 символов.');
    var cat = categories.find(function(c){return c.age === data.age && c.weight === data.weight;});
    if (!cat) fail('Выберите возраст и вес из списка.');
    if (event.belts && (!data.belt || data.allowedBelts.indexOf(data.belt)<0)) fail('Выберите пояс из списка.');
    return {name:name,age:cat.age,weight:cat.weight,belt:event.belts?data.belt:'',club:typeof BJJ2!=='undefined'?BJJ2.clubName(data.club||''):''};
  }
  function savePerson(db, eventId, data, userId, categories, participantId, allowDuplicate) {
    var event = editable(db,eventId), clean = validatePerson(data,event,categories);
    var current = participantId ? byId(db.participants,participantId) : null;
    if (participantId && (!current || current.eventId!==eventId)) fail('Участник не найден.');
    if(current&&data.expectedRev!==undefined&&current.rev!==data.expectedRev)fail('Данные участника изменились. Откройте карточку заново.');
    if(!current&&roster(db,event).length>=300)fail('Максимум 300 участников в турнире.');
    if (userId && db.participants.some(function(p){return p.eventId===eventId && p.userId===String(userId) && p.status==='Зарегистрирован' && p.id!==participantId;})) fail('Вы уже зарегистрированы. Откройте «Моя регистрация».');
    if (!allowDuplicate && roster(db,event).some(function(p){return p.id!==participantId && p.name.toLocaleLowerCase()===clean.name.toLocaleLowerCase();})) fail('DUPLICATE_NAME');
    if (!current) { current={id:id(db,'p'),eventId:eventId,userId:userId?String(userId):'',registeredAt:new Date().toISOString()}; db.participants.push(current); }
    Object.keys(clean).forEach(function(k){current[k]=clean[k];});
    current.rev=(current.rev||0)+1;
    if(typeof BJJ2!=='undefined'){current.clubId=BJJ2.club(db,current.club);if(current.clubId)current.club=BJJ.byId(db.clubs,current.clubId).name;}
    current.status='Зарегистрирован'; event.version++; return current;
  }
  function cancelPerson(db,eventId,participantId) {
    var e=editable(db,eventId), p=byId(db.participants,participantId);
    if (!p || p.eventId!==e.id || p.status!=='Зарегистрирован') fail('Активная регистрация не найдена.');
    p.status='Отменена';p.rev=(p.rev||0)+1; e.version++;
  }
  function validateMerge(groups, selection) {
    if (selection.length<2 || new Set(selection).size!==selection.length) fail('Выберите минимум две разные категории.');
    if (groups.some(function(g){return g.some(function(x){return selection.indexOf(x)>=0;});})) fail('Одна из категорий уже объединена. Сначала сбросьте объединения.');
  }
  function mergedName(groups,value) { var found=groups.find(function(g){return g.indexOf(value)>=0;}); return (found?found.slice().sort():[value]).join(' + '); }
  function preview(db,e) {
    var list=roster(db,e), buckets={};
    if(!list.length) fail('Нет зарегистрированных участников.');
    if(e.belts && list.some(function(p){return !p.belt;})) fail('Есть участники без пояса. Отредактируйте их или отключите учет поясов.');
    list.forEach(function(p){
      var weight=mergedName(e.mergeWeights[p.age]||[],p.weight);
      var belt=e.belts?mergedName(e.mergeBelts,p.belt):'Без деления по поясам';
      var key=JSON.stringify([p.age,weight,belt]);
      if(!buckets[key]) buckets[key]={age:p.age,weight:weight,belt:belt,participantIds:[]};
      buckets[key].participantIds.push(p.id);
    });
    var result=Object.keys(buckets).sort().map(function(k){return buckets[k];});
    var total=0;
    result.forEach(function(g){var n=g.participantIds.length;
      if(typeof BJJ2!=='undefined')Object.assign(g,BJJ2.category(db,e,g));else g.system=e.system;
      if(n>(g.system==='Круговая'?64:128)) fail('В группе слишком много участников: максимум 64 для круговой или 128 для олимпийской системы.');
      g.count=n;g.roundRobinCount=n*(n-1)/2;g.knockoutCount=n-1; g.fightCount=g.system==='Круговая'?g.roundRobinCount:g.knockoutCount;g.estimatedMinutes=g.fightCount*((g.durationSec||300)+(g.gapSec===undefined?60:g.gapSec))/60; total+=g.fightCount;
    });
    if(total>4000) fail('Слишком много схваток для одной таблицы: максимум 4000.');
    return result;
  }
  function shuffled(list,random) { var a=list.slice(); for(var i=a.length-1;i>0;i--){var j=Math.floor(random()*(i+1)),t=a[i];a[i]=a[j];a[j]=t;} return a; }
  function bracket(db,group,random) {
    var players=shuffled(group.participantIds,random), n=players.length;
    if(n<2) return [];
    var size=2; while(size<n) size*=2;
    var byes=size-n, pairs=[], cursor=0;
    for(var i=0;i<byes;i++) pairs.push([players[cursor++],null]);
    while(cursor<n) pairs.push([players[cursor++],players[cursor++]]);
    pairs=shuffled(pairs,random);
    var rounds=[], out=[];
    for(var round=1,width=size/2;width>=1;round++,width/=2){
      var row=[];
      for(var m=0;m<width;m++){
        var match={id:id(db,'m'),eventId:group.eventId,groupId:group.id,round:round,number:out.length+1,a:round===1?pairs[m][0]:null,b:round===1?pairs[m][1]:null,winner:null,status:'Ожидает участников',next:null,nextSlot:null,sourceA:null,sourceB:null,rev:1};
        row.push(match);out.push(match);
      }
      rounds.push(row);
    }
    for(var r=0;r<rounds.length-1;r++) rounds[r].forEach(function(m,i){var next=rounds[r+1][Math.floor(i/2)];m.next=next.id;m.nextSlot=i%2?'B':'A';next[i%2?'sourceB':'sourceA']=m.id;});
    out.forEach(function(m){if(m.round===1){if(!m.b){m.status='Проход без боя';m.winner=m.a;}else m.status='Готова';}});
    rounds[0].forEach(function(m){if(m.winner) propagate(out,m);});
    return out;
  }
  function roundRobin(db,group,random) {
    var ring=shuffled(group.participantIds,random), out=[];
    if(ring.length<2)return out;
    if(ring.length%2)ring.push(null);
    var count=ring.length;
    for(var r=1;r<count;r++){
      for(var i=0;i<count/2;i++){
        var a=ring[i],b=ring[count-1-i];if(!a||!b)continue;
        out.push({id:id(db,'m'),eventId:group.eventId,groupId:group.id,round:r,number:out.length+1,a:a,b:b,winner:null,status:'Готова',next:null,nextSlot:null,sourceA:null,sourceB:null,rev:1});
      }
      ring.splice(1,0,ring.pop());
    }
    return out;
  }
  function propagate(matches,match) {
    if(!match.next)return;
    var next=byId(matches,match.next);next[match.nextSlot==='A'?'a':'b']=match.winner;
    next.rev++;next.status=next.a&&next.b?'Готова':'Ожидает участников';
  }
  function generate(db,eventId,version,random) {
    var e=active(db); if(!e||e.id!==eventId||e.version!==version)fail('Состав или настройки изменились. Откройте новый предварительный просмотр.');
    if(db.matches.some(function(m){return m.eventId===eventId&&(m.status==='Завершена'||m.actualStart);}))fail('Жеребьевку нельзя изменить после начала схватки или внесения результата.');
    if(e.status!=='Регистрация'&&e.status!=='Сетки сформированы')fail('Соревнование завершено.');
    var groups=preview(db,e);
    if(groups.some(function(g){return g.conflicts&&g.conflicts.length;}))fail('Разрешите конфликт настроек категорий перед жеребьевкой.');
    db.groups=db.groups.filter(function(g){return g.eventId!==eventId;});
    db.matches=db.matches.filter(function(m){return m.eventId!==eventId;});
    groups.forEach(function(p){var g=Object.assign({},p,{id:id(db,'g'),eventId:e.id,rev:1});db.groups.push(g);db.matches=db.matches.concat(g.system==='Круговая'?roundRobin(db,g,random||Math.random):bracket(db,g,random||Math.random));});
    var publicNumber=1;db.matches.filter(function(m){return m.eventId===e.id;}).forEach(function(m){m.publicNumber=m.status==='Проход без боя'?null:publicNumber++;});
    e.scheduleDraft=null;e.schedulePublished=null;
    e.status='Сетки сформированы';e.version++;e.ties={};return db.groups.filter(function(g){return g.eventId===e.id;});
  }
  function setWinner(db,matchId,winnerId,revision) {
    var e=active(db), m=byId(db.matches,matchId);
    if(!m||!e||m.eventId!==e.id||e.status!=='Сетки сформированы'||m.rev!==revision)fail('Эта кнопка устарела. Откройте список схваток заново.');
    if(['Готова','Идёт','Завершена'].indexOf(m.status)<0||!m.a||!m.b||(winnerId!==m.a&&winnerId!==m.b))fail('Нельзя выбрать победителя этой схватки.');
    var next=m.next?byId(db.matches,m.next):null;
    if(next&&(next.winner||next.actualStart))fail('Следующая схватка уже начата или имеет результат. Её нужно исправить первой.');
    m.winner=winnerId;m.status='Завершена';m.actualEnd=m.actualEnd||new Date().toISOString();m.rev++;propagate(db.matches,m);e.ties={};e.version++;
    return m;
  }
  function clearWinner(db,matchId,revision) {
    var e=active(db),m=byId(db.matches,matchId);
    if(!e||e.status!=='Сетки сформированы'||!m||m.eventId!==e.id||m.rev!==revision||m.status!=='Завершена')fail('Результат недоступен для изменения.');
    var next=m.next?byId(db.matches,m.next):null;if(next&&(next.winner||next.actualStart))fail('Сначала исправьте результат или начало следующей схватки.');
    m.winner=null;m.status='Готова';m.actualStart=null;m.actualEnd=null;m.rev++;if(next){next[m.nextSlot==='A'?'a':'b']=null;next.status='Ожидает участников';next.rev++;}e.ties={};e.version++;
  }
  function standings(db,group) {
    var event=byId(db.events,group.eventId);if(event&&event.finishMode==='withoutResults')return {complete:false,rows:group.participantIds.map(function(id){return {id:id,place:null,wins:db.matches.filter(function(m){return m.groupId===group.id&&m.winner===id&&m.status==='Завершена';}).length};}),ties:[],withoutResults:true};
    var matches=db.matches.filter(function(m){return m.groupId===group.id;});
    var complete=matches.every(function(m){return !!m.winner;});
    if(group.participantIds.length===1)return {complete:true,rows:[{id:group.participantIds[0],place:1,wins:0}],ties:[]};
    if(group.system==='Олимпийская'){
      if(!complete)return {complete:false,rows:[],ties:[]};
      var final=matches.find(function(m){return !m.next;});
      var rows=[{id:final.winner,place:1},{id:final.a===final.winner?final.b:final.a,place:2}];
      matches.filter(function(m){return m.next===final.id&&m.a&&m.b&&m.status==='Завершена';}).forEach(function(m){rows.push({id:m.a===m.winner?m.b:m.a,place:3});});
      return {complete:true,rows:rows,ties:[]};
    }
    var counts={};group.participantIds.forEach(function(p){counts[p]=0;});matches.forEach(function(m){if(m.winner)counts[m.winner]++;});
    var wins=Object.keys(counts).map(function(p){return {id:p,wins:counts[p]};}).sort(function(a,b){return b.wins-a.wins||a.id.localeCompare(b.id);});
    var ties=[],ordered=[],e=byId(db.events,group.eventId);
    for(var i=0;i<wins.length;){var end=i+1;while(end<wins.length&&wins[end].wins===wins[i].wins)end++;
      var block=wins.slice(i,end), key=group.id+':'+wins[i].wins, override=e.ties[key];
      if(complete&&block.length>1){
        if(override&&override.length===block.length&&override.every(function(p){return block.some(function(b){return b.id===p;});}))block=override.map(function(p){return block.find(function(b){return b.id===p;});});
        else if(block.length===2){var head=matches.find(function(m){return (m.a===block[0].id&&m.b===block[1].id)||(m.a===block[1].id&&m.b===block[0].id);});if(head&&head.winner===block[1].id)block.reverse();}
        else ties.push({key:key,ids:block.map(function(b){return b.id;}),start:i+1,wins:block[0].wins});
      }
      block.forEach(function(b,j){b.place=complete&&!ties.some(function(t){return t.ids.indexOf(b.id)>=0;})?i+j+1:null;ordered.push(b);});i=end;
    }
    return {complete:complete,rows:ordered,ties:ties};
  }
  function finish(db,eventId) {
    var e=active(db);if(!e||e.id!==eventId||e.status!=='Сетки сформированы')fail('Нет активного турнира с сетками.');
    var groups=db.groups.filter(function(g){return g.eventId===e.id;});
    if(!groups.length||groups.some(function(g){var s=standings(db,g);return !s.complete||s.ties.length;}))fail('Сначала завершите схватки и разрешите равенство мест.');
    e.status='Завершено';e.version++;
  }
  function archive(db,eventId) {var e=active(db);if(!e||e.id!==eventId||e.status!=='Завершено')fail('Сначала завершите соревнование.');e.status='Архив';e.version++;}
  return {empty:empty,clone:clone,id:id,active:active,byId:byId,roster:roster,editable:editable,createEvent:createEvent,savePerson:savePerson,cancelPerson:cancelPerson,validateMerge:validateMerge,preview:preview,generate:generate,setWinner:setWinner,clearWinner:clearWinner,standings:standings,finish:finish,archive:archive};
})();


/* Shared deterministic domain: Apps Script, Node tests and iOS JavaScriptCore. */
var BJJ2=(function(){
  'use strict';
  var VERSION='2.0.0';
  var TABLES=['events','participants','groups','matches','clubs','categoryConfigs','mats','scheduleDraft','schedulePublished'];
  var PRIVATE=['devices','challenges','operations'];
  function fail(s){throw new Error(s);}
  function own(o,k){return Object.prototype.hasOwnProperty.call(o,k);}
  function clean(s,max){s=String(s||'').replace(/\s+/g,' ').trim();if(s.length>max||/[\x00-\x1f]/.test(s))fail('Некорректная длина или символы.');return s;}
  function clubName(s){return clean(s,100);}
  function club(db,name){name=clubName(name);if(!name)return '';var c=db.clubs.find(function(c){return c.name.toLowerCase()===name.toLowerCase();});if(!c){c={id:BJJ.id(db,'club'),name:name,rev:1};db.clubs.push(c);}return c.id;}
  function migrate(db){
    if(db.schema!==1&&db.schema!==2)fail('Неподдерживаемая версия данных.');
    db.schema=2;db.revision=db.revision||0;db.changeFloor=db.changeFloor||0;
    TABLES.concat(PRIVATE,['changes']).forEach(function(k){if(!db[k])db[k]=[];});
    db.events.forEach(function(e){if(!e.templates)e.templates={young:120,child:180,adult:300,black:600};if(e.restSec===undefined)e.restSec=300;if(e.gapSec===undefined)e.gapSec=60;if(!e.categoryOrder)e.categoryOrder=[];if(!e.matNotBefore)e.matNotBefore={};});
    db.participants.forEach(function(p){p.rev=p.rev||1;p.club=p.club||'';p.clubId=p.clubId||club(db,p.club);});
    db.groups.forEach(function(g){g.rev=g.rev||1;});
    db.events.forEach(function(e){var next=1;db.matches.filter(function(m){return m.eventId===e.id;}).forEach(function(m){if(m.publicNumber===undefined)m.publicNumber=m.status==='Проход без боя'?null:next; if(m.publicNumber)next=Math.max(next,m.publicNumber+1);});});
    return db;
  }
  function seedRandom(seed){var a=2166136261;String(seed).split('').forEach(function(c){a=Math.imul(a^c.charCodeAt(0),16777619);});return function(){a+=0x6D2B79F5;var t=a;t=Math.imul(t^t>>>15,t|1);t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296;};}
  function atom(p){return JSON.stringify([p.age,p.weight,p.belt||'']);}
  function duration(e,p){var t=e.templates||{young:120,child:180,adult:300,black:600};return p.age==='Взрослые (18+)'?(p.belt==='Черный'?t.black:t.adult):/4[–-]6/.test(p.age)?t.young:t.child;}
  function category(db,e,g){
    var people=g.participantIds.map(function(id){return BJJ.byId(db.participants,id);}),members=Array.from(new Set(people.map(atom))).sort(),key=JSON.stringify([g.age,g.weight,g.belt]);
    var rules=(db.categoryConfigs||[]).filter(function(c){return c.eventId===e.id;}),exact=rules.find(function(c){return c.key===key;}),conflicts=[],out={key:key,members:members};
    ['system','durationSec','restSec','gapSec','matId'].forEach(function(field){
      var values=people.map(function(p){var matching=rules.filter(function(c){return own(c,field)&&(c.key===key||(c.members||[]).indexOf(atom(p))>=0);}).sort(function(a,b){return ((a.stamps||{})[field]||parseInt(a.id.slice(3),36)||0)-((b.stamps||{})[field]||parseInt(b.id.slice(3),36)||0);});var rule=matching[matching.length-1];var value=rule?rule[field]:null;
        if(value===null||value===undefined)value=field==='system'?e.system:field==='durationSec'?duration(e,p):field==='restSec'?e.restSec===undefined?300:e.restSec:field==='gapSec'?e.gapSec===undefined?60:e.gapSec:null;return value;});
      var unique=Array.from(new Set(values));if(unique.length>1)conflicts.push(field);out[field]=unique[0];
    });out.conflicts=conflicts;return out;
  }
  function integer(n,min,max){if(!Number.isSafeInteger(n)||n<min||n>max)fail('Значение вне допустимого диапазона: '+min+'–'+max);return n;}
  function iso(s){var t=Date.parse(s);if(!Number.isFinite(t))fail('Укажите корректное время с часовым поясом.');return new Date(t).toISOString();}
  function event(db,id){var e=BJJ.active(db);if(!e||e.id!==id)fail('Активный турнир изменился.');return e;}
  function revision(actual,expected){if(actual!==expected)fail('CONFLICT: данные изменились. Обновите экран.');}
  function permutation(ids,expected){if(!Array.isArray(ids)||ids.length!==expected.length||new Set(ids).size!==ids.length||ids.some(function(id){return expected.indexOf(id)<0;}))fail('Нужен полный порядок без повторов.');}
  function validateOrder(db,group,ids){var byId={},position={};db.matches.forEach(function(m){byId[m.id]=m;});ids.forEach(function(id,i){position[id]=i;});var round=0;ids.forEach(function(id){var m=byId[id];if(group.system==='Круговая'&&m.round<round)fail('Нельзя нарушать порядок раундов круговой системы.');round=m.round;['sourceA','sourceB'].forEach(function(k){var source=byId[m[k]];if(source&&source.status!=='Проход без боя'&&position[source.id]>=position[id])fail('Схватка должна следовать после своих предшественников.');});});}
  function editable(e){if(e.status!=='Регистрация')fail('Изменение состава доступно до жеребьевки.');}
  function buildSchedule(db,e,now){
    if(e.status!=='Сетки сформированы')fail('Сначала сформируйте сетки.');if(!e.startAt)fail('Укажите время начала турнира.');
    var mats=db.mats.filter(function(m){return m.eventId===e.id;}),groups=db.groups.filter(function(g){return g.eventId===e.id;}),matches=db.matches.filter(function(m){return m.eventId===e.id;}),byId={},slots={},last={},possibleCache={},out=[];
    matches.forEach(function(m){byId[m.id]=m;});
    function possible(m,side){var id=m[side];if(id)return [id];var source=m[side==='a'?'sourceA':'sourceB'];if(!source)return [];var prev=byId[source];if(!prev)fail('Повреждена зависимость сетки.');if(prev.winner)return [prev.winner];if(!possibleCache[source])possibleCache[source]=Array.from(new Set(possible(prev,'a').concat(possible(prev,'b'))));return possibleCache[source];}
    var order=e.categoryOrder||[];groups.sort(function(a,b){var ai=order.indexOf(a.id),bi=order.indexOf(b.id);return (ai<0?9999:ai)-(bi<0?9999:bi)||a.id.localeCompare(b.id);});
    var cursor={};mats.forEach(function(m){cursor[m.id]=Date.parse(e.startAt);});
    groups.forEach(function(g){var cfg=category(db,e,g);if(cfg.conflicts.length)fail('Конфликт настроек категории.');var live=matches.filter(function(m){return m.groupId===g.id&&m.status!=='Проход без боя'&&['Не состоялась','Не завершена'].indexOf(m.status)<0;});if(!live.length)return;
      if(!cfg.matId||!own(cursor,cfg.matId))fail('Назначьте ковёр каждой категории со схватками.');
      var rule=db.categoryConfigs.find(function(r){return r.eventId===e.id&&r.key===cfg.key;}),custom=rule&&rule.matchOrder||[];
      live.sort(function(a,b){return custom.length?custom.indexOf(a.id)-custom.indexOf(b.id):a.round-b.round||a.number-b.number;});if(custom.length)permutation(custom,live.map(function(m){return m.id;}));
      var lastRound=0;
      live.forEach(function(m){if(g.system==='Круговая'&&m.round<lastRound)fail('Нельзя нарушать порядок раундов круговой системы.');lastRound=m.round;
        var frozen=m.actualStart||m.winner,old=db.schedulePublished.find(function(s){return s.matchId===m.id;}),matId=frozen&&old?old.matId:cfg.matId;
        if(!own(cursor,matId))fail('Ковёр проведённой схватки нельзя удалить.');
        var ids=Array.from(new Set(possible(m,'a').concat(possible(m,'b')))),start=cursor[matId],end;
        ['sourceA','sourceB'].forEach(function(k){var prev=byId[m[k]];if(prev&&prev.status!=='Проход без боя'){if(!slots[prev.id])fail('Схватка должна следовать после своих предшественников.');start=Math.max(start,Date.parse(slots[prev.id].endAt)+cfg.restSec*1000);}});
        ids.forEach(function(id){if(last[id])start=Math.max(start,last[id]+cfg.restSec*1000);});
        if(frozen){end=m.actualEnd?Date.parse(m.actualEnd):Math.max(now,Date.parse(m.actualStart)+cfg.durationSec*1000);start=m.actualStart?Date.parse(m.actualStart):old?Math.min(Date.parse(old.startAt),end):end;
          if(end<start)fail('Окончание раньше начала.');
        }else{start=Math.max(start,e.matNotBefore[matId]?Date.parse(e.matNotBefore[matId]):0,now||0);end=start+cfg.durationSec*1000;}
        // Past facts are immutable; reject a proposed order that inserts future bouts before them.
        if(frozen&&out.some(function(s){return s.matId===matId&&!s.frozen&&Date.parse(s.endAt)>start;}))fail('Нельзя переставить будущую схватку перед уже начатой.');
        var slot={id:e.id+':'+m.id,eventId:e.id,matchId:m.id,groupId:g.id,matId:matId,number:m.publicNumber,startAt:new Date(start).toISOString(),endAt:new Date(end).toISOString(),frozen:!!frozen};
        slots[m.id]=slot;out.push(slot);cursor[matId]=Math.max(cursor[matId],end+cfg.gapSec*1000);ids.forEach(function(id){last[id]=Math.max(last[id]||0,end);});
      });
    });return out;
  }
  function recalculate(db,e,now,publish){var slots=buildSchedule(db,e,now);db.scheduleDraft=db.scheduleDraft.filter(function(s){return s.eventId!==e.id;}).concat(slots);e.scheduleDraftAt=new Date(now).toISOString();if(publish){db.schedulePublished=db.schedulePublished.filter(function(s){return s.eventId!==e.id;}).concat(BJJ.clone(slots));e.schedulePublishedAt=e.scheduleDraftAt;}return slots;}
  function finishWithout(db,e){if(['Регистрация','Сетки сформированы'].indexOf(e.status)<0)fail('Турнир уже завершён.');e.status='Завершено';e.finishMode='withoutResults';e.finishedAt=new Date().toISOString();e.version++;db.matches.filter(function(m){return m.eventId===e.id&&!m.winner;}).forEach(function(m){m.status=m.actualStart?'Не завершена':'Не состоялась';m.rev++;});db.scheduleDraft=db.scheduleDraft.filter(function(s){return s.eventId!==e.id;});db.schedulePublished=db.schedulePublished.filter(function(s){return s.eventId!==e.id||s.frozen;});e.scheduleDraftAt=null;e.schedulePublishedAt=e.finishedAt;}
  function command(db,action,p,config){
    migrate(db);p=p||{};var now=config&&config.now!==undefined?config.now:Date.now(),e=action==='event.create'?null:event(db,p.eventId),m;
    var matchAction=action.indexOf('match.')===0&&action!=='match.order';
    if(matchAction){m=BJJ.byId(db.matches,p.matchId);if(!m||m.eventId!==e.id)fail('Схватка не найдена.');revision(m.rev,p.expectedRev);}
    else if(action==='participant.save'&&p.participantId){var person=BJJ.byId(db.participants,p.participantId);if(!person||person.eventId!==e.id)fail('Участник не найден.');revision(person.rev,p.expectedRev);}
    else if(e)revision(e.version,p.expectedVersion);
    var oldPublished=e&&!!e.schedulePublishedAt,needsSchedule=false,result={};
    if(action==='event.create'){var created=BJJ.createEvent(db,p.title,p.date||'',p.system||'Олимпийская',p.belts!==false);migrate(db);return {eventId:created.id};}
    if(action==='event.system'){editable(e);if(['Круговая','Олимпийская'].indexOf(p.system)<0)fail('Неизвестная система.');e.system=p.system;e.version++;}
    else if(action==='event.belts'){editable(e);if(typeof p.enabled!=='boolean')fail('Нужно логическое значение.');e.belts=p.enabled;e.version++;}
    else if(action==='event.templates'){Object.keys(e.templates).forEach(function(k){if(own(p,k))e.templates[k]=integer(p[k],30,3600);});if(own(p,'restSec'))e.restSec=integer(p.restSec,0,7200);if(own(p,'gapSec'))e.gapSec=integer(p.gapSec,0,3600);e.version++;needsSchedule=true;}
    else if(action==='event.start'){e.startAt=iso(p.startAt);e.version++;needsSchedule=true;}
    else if(action==='event.finishWithoutResults')finishWithout(db,e);
    else if(action==='event.finish'){BJJ.finish(db,e.id);e.finishMode='results';}
    else if(action==='event.archive')BJJ.archive(db,e.id);
    else if(action==='participant.save'){var data=Object.assign({},p.person,{expectedRev:p.expectedRev});data.allowedBelts=data.age==='Взрослые (18+)'?config.adultBelts:config.childBelts;var saved=BJJ.savePerson(db,e.id,data,p.userId||'',config.categories,p.participantId,!!p.allowDuplicate);result={participantId:saved.id};}
    else if(action==='participant.cancel')BJJ.cancelPerson(db,e.id,p.participantId);
    else if(action==='club.rename'){editable(e);var c=BJJ.byId(db.clubs,p.clubId),name=clubName(p.name);if(!c||!name)fail('Клуб не найден или название пусто.');if(db.clubs.some(function(x){return x.id!==c.id&&x.name.toLowerCase()===name.toLowerCase();}))fail('Клуб с таким названием уже есть.');c.name=name;c.rev++;db.participants.filter(function(x){return x.eventId===e.id&&x.clubId===c.id;}).forEach(function(x){x.club=name;x.rev++;});e.version++;}
    else if(action==='category.configure'){
      var groups=e.status==='Регистрация'?BJJ.preview(db,e):db.groups.filter(function(g){return g.eventId===e.id;}),g=groups.find(function(g){return g.key===p.key||JSON.stringify([g.age,g.weight,g.belt])===p.key;});if(!g)fail('Категория изменилась.');
      var cfg=category(db,e,g),r=db.categoryConfigs.find(function(x){return x.eventId===e.id&&x.key===cfg.key;});if(!r){r={id:BJJ.id(db,'cfg'),eventId:e.id,key:cfg.key,members:cfg.members};db.categoryConfigs.push(r);}r.members=cfg.members;if(!r.stamps)r.stamps={};
      if(own(p,'system')){if(e.status!=='Регистрация')fail('Систему меняют до жеребьевки.');if(p.system!==null&&['Круговая','Олимпийская'].indexOf(p.system)<0)fail('Неизвестная система.');r.system=p.system;}
      ['durationSec','restSec','gapSec'].forEach(function(k){if(own(p,k))r[k]=p[k]===null?null:integer(p[k],k==='durationSec'?30:0,k==='restSec'?7200:3600);});
      if(own(p,'matId')){if(p.matId!==null&&!db.mats.some(function(x){return x.id===p.matId&&x.eventId===e.id;}))fail('Ковёр не найден.');r.matId=p.matId;}
      ['system','durationSec','restSec','gapSec','matId'].forEach(function(k){if(own(p,k))r.stamps[k]=db.next++;});
      e.version++;needsSchedule=true;
    }
    else if(action==='category.merge'){editable(e);if(!Array.isArray(p.values)||p.values.some(function(v){return typeof v!=='string';}))fail('Нужен список категорий.');if(p.kind==='belt'){if(!e.belts)fail('Деление по поясам отключено.');if(p.values.some(function(v){return config.childBelts.concat(config.adultBelts).indexOf(v)<0;}))fail('Неизвестный пояс.');BJJ.validateMerge(e.mergeBelts,p.values);e.mergeBelts.push(p.values.slice());}else if(p.kind==='weight'){var allowed=config.categories.filter(function(c){return c.age===p.age;}).map(function(c){return c.weight;});if(p.values.some(function(v){return allowed.indexOf(v)<0;}))fail('Неизвестный вес.');var list=e.mergeWeights[p.age]||[];BJJ.validateMerge(list,p.values);list.push(p.values.slice());e.mergeWeights[p.age]=list;}else fail('Неизвестное объединение.');e.version++;}
    else if(action==='category.reset'){editable(e);e.mergeBelts=[];e.mergeWeights={};e.version++;}
    else if(action==='mats.save'){if(!Array.isArray(p.mats))fail('Нужен список ковров.');integer(p.mats.length,1,3);var old=db.mats.filter(function(x){return x.eventId===e.id;}),ids=new Set();var mats=p.mats.map(function(x){var name=clean(x.name,60);if(!name)fail('Введите название ковра.');if(x.id&&!old.some(function(m){return m.id===x.id;}))fail('Ковёр не найден.');var id=x.id||BJJ.id(db,'mat');if(ids.has(id))fail('Повтор ковра.');ids.add(id);return {id:id,eventId:e.id,name:name};});if(db.schedulePublished.some(function(s){return s.eventId===e.id&&s.frozen&&!ids.has(s.matId);}))fail('Нельзя удалить ковёр начатой схватки.');db.mats=db.mats.filter(function(x){return x.eventId!==e.id;}).concat(mats);e.version++;needsSchedule=true;}
    else if(action==='category.order'){permutation(p.ids,db.groups.filter(function(g){return g.eventId===e.id;}).map(function(g){return g.id;}));e.categoryOrder=p.ids.slice();e.version++;needsSchedule=true;}
    else if(action==='match.order'){var group=BJJ.byId(db.groups,p.groupId);if(!group||group.eventId!==e.id)fail('Группа не найдена.');var all=db.matches.filter(function(m){return m.groupId===group.id&&m.status!=='Проход без боя';});permutation(p.ids,all.map(function(m){return m.id;}));validateOrder(db,group,p.ids);var cg=category(db,e,group),cr=db.categoryConfigs.find(function(r){return r.eventId===e.id&&r.key===cg.key;});if(!cr){cr={id:BJJ.id(db,'cfg'),eventId:e.id,key:cg.key,members:cg.members};db.categoryConfigs.push(cr);}cr.matchOrder=p.ids.slice();e.version++;needsSchedule=true;}
    else if(action==='draw.preview'){var preview=BJJ.preview(db,e);return {groups:preview,engineVersion:VERSION};}
    else if(action==='draw.commit'){if(typeof p.seed!=='string'||!p.seed||p.seed.length>128)fail('Нужен seed жеребьевки.');BJJ.generate(db,e.id,e.version,seedRandom(p.seed));e.drawSeed=p.seed;e.categoryOrder=db.groups.filter(function(g){return g.eventId===e.id;}).map(function(g){return g.id;});db.categoryConfigs.filter(function(r){return r.eventId===e.id;}).forEach(function(r){delete r.matchOrder;});db.scheduleDraft=db.scheduleDraft.filter(function(s){return s.eventId!==e.id;});db.schedulePublished=db.schedulePublished.filter(function(s){return s.eventId!==e.id;});e.schedulePublishedAt=null;e.scheduleDraftAt=null;}
    else if(action==='schedule.preview'){recalculate(db,e,now,false);result={count:db.scheduleDraft.filter(function(s){return s.eventId===e.id;}).length};}
    else if(action==='schedule.publish'){if(p.expectedDraftAt!==e.scheduleDraftAt)fail('CONFLICT: предпросмотр расписания изменился.');if(!e.scheduleDraftAt)fail('Сначала рассчитайте черновик.');db.schedulePublished=db.schedulePublished.filter(function(s){return s.eventId!==e.id;}).concat(BJJ.clone(db.scheduleDraft.filter(function(s){return s.eventId===e.id;})));e.schedulePublishedAt=new Date(now).toISOString();e.version++;}
    else if(action==='mat.shift'){var mat=BJJ.byId(db.mats,p.matId);if(!mat||mat.eventId!==e.id)fail('Ковёр не найден.');integer(p.seconds,-86400,86400);var first=db.schedulePublished.filter(function(s){return s.matId===mat.id&&!s.frozen;}).sort(function(a,b){return a.startAt.localeCompare(b.startAt);})[0];e.matNotBefore[mat.id]=new Date((first?Date.parse(first.startAt):now)+p.seconds*1000).toISOString();e.version++;needsSchedule=true;}
    else if(action==='match.start'){if(e.status!=='Сетки сформированы'||m.status!=='Готова'||!m.a||!m.b)fail('Схватка ещё не готова.');var slot=db.schedulePublished.find(function(s){return s.matchId===m.id;});if(!slot)fail('Сначала опубликуйте расписание.');if(db.matches.some(function(x){var s=db.schedulePublished.find(function(y){return y.matchId===x.id;});return x.status==='Идёт'&&s&&s.matId===slot.matId;}))fail('На ковре уже идёт схватка.');var next=db.schedulePublished.filter(function(s){var bout=BJJ.byId(db.matches,s.matchId);return s.matId===slot.matId&&bout&&!bout.winner;}).sort(function(a,b){return a.startAt.localeCompare(b.startAt);})[0];if(next&&next.matchId!==m.id)fail('Сначала проведите предыдущую схватку или измените порядок.');if(Date.parse(slot.startAt)>now)fail('Рано начинать: проверьте отдых и порядок расписания.');m.status='Идёт';m.actualStart=new Date(now).toISOString();m.rev++;needsSchedule=true;}
    else if(action==='match.result'){BJJ.setWinner(db,m.id,p.winnerId,m.rev);m.actualEnd=new Date(now).toISOString();needsSchedule=true;}
    else if(action==='match.clear'){BJJ.clearWinner(db,m.id,m.rev);needsSchedule=true;}
    else if(action==='match.times'){if(!m.actualStart&&!m.winner)fail('Схватка ещё не начата.');if(p.actualStart)m.actualStart=iso(p.actualStart);if(p.actualEnd){if(!m.winner)fail('Сначала внесите результат.');m.actualEnd=iso(p.actualEnd);}if(m.actualEnd&&Date.parse(m.actualEnd)<Date.parse(m.actualStart))fail('Окончание раньше начала.');m.rev++;needsSchedule=true;}
    else if(action==='tie.resolve'){var tg=BJJ.byId(db.groups,p.groupId);if(!tg||tg.eventId!==e.id)fail('Группа не найдена.');var tie=BJJ.standings(db,tg).ties.find(function(t){return t.key===p.key;});if(!tie)fail('Равенство уже изменилось.');permutation(p.ids,tie.ids);e.ties[tie.key]=p.ids.slice();e.version++;}
    else fail('Неизвестная команда.');
    if(matchAction&&action!=='match.result'&&action!=='match.clear')e.version++;
    if(needsSchedule){if(e.status!=='Регистрация'&&e.status!=='Сетки сформированы')fail('Турнир завершён.');if(e.status==='Сетки сформированы'&&(oldPublished||e.scheduleDraftAt))recalculate(db,e,now,oldPublished);}
    return result;
  }
  function transact(db,action,p,config){var draft=BJJ.clone(db),result=command(draft,action,p,config||{});return {db:draft,result:result};}
  function finalize(before,after){
    migrate(before);migrate(after);var pending=[];
    TABLES.forEach(function(type){var old={},next={};before[type].forEach(function(r){old[r.id]=r;});after[type].forEach(function(r){next[r.id]=r;if(JSON.stringify(r)!==JSON.stringify(old[r.id])){if(type!=='events'&&(!old[r.id]||r.rev===old[r.id].rev||!Number.isSafeInteger(r.rev)))r.rev=((old[r.id]||{}).rev||0)+1;pending.push({type:type,entityId:r.id,record:BJJ.clone(r)});}});Object.keys(old).forEach(function(id){if(!next[id])pending.push({type:type,entityId:id,deleted:true});});});
    if(!pending.length)return false;after.revision=(before.revision||0)+1;after.projectionDirty=true;pending.forEach(function(c,i){c.id='c'+after.revision+'_'+i;c.revision=after.revision;after.changes.push(c);});
    if(after.changes.length>5000){var removed=after.changes.splice(0,after.changes.length-5000);after.changeFloor=Math.max(after.changeFloor,removed[removed.length-1].revision);}return true;
  }
  function snapshot(db){var out={schema:2,next:db.next,revision:db.revision,engineVersion:VERSION};TABLES.forEach(function(k){out[k]=BJJ.clone(db[k]||[]);});return out;}
  function sync(db,cursor){if(!Number.isSafeInteger(cursor)||cursor<db.changeFloor||cursor>db.revision)return {snapshot:snapshot(db),cursor:db.revision};return {changes:db.changes.filter(function(c){return c.revision>cursor;}),cursor:db.revision,next:db.next,engineVersion:VERSION};}
  function candidates(db,m){function side(key){if(m[key])return [m[key]];var source=BJJ.byId(db.matches,m[key==='a'?'sourceA':'sourceB']);return !source?[]:source.winner?[source.winner]:candidates(db,source);}return Array.from(new Set(side('a').concat(side('b'))));}
  return {VERSION:VERSION,TABLES:TABLES,PRIVATE:PRIVATE,migrate:migrate,clubName:clubName,club:club,category:category,seedRandom:seedRandom,buildSchedule:buildSchedule,recalculate:recalculate,finishWithout:finishWithout,command:command,transact:transact,finalize:finalize,snapshot:snapshot,sync:sync,candidates:candidates};
})();
