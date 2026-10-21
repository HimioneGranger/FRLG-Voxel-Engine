-- Editable lighting policy; no changes to saves or native geometry.
return {
 streetLampsEnabled=false, -- User preference: keep building/indoor lighting only.
 policy={
  duskMinute=18*60,duskFade=30,dawnMinute=6*60,dawnFade=30,
  shutdownStart=22*60,shutdownEnd=24*60+50,shutdownFade=10,variation=10,
  lampDuskMinute=18*60,lampDuskFade=30,lampDawnMinute=6*60,lampDawnFade=30,
  profiles={house={1,.83,.60},service={.87,.94,1},other={1,.89,.73},streetlamp={1,.76,.28}},
  indoorProfiles={house={mul={1,.97,.91},add={.015,.010,.003}},service={mul={.98,.99,1},add={.025,.025,.030}}},
  exceptions={},indoorExceptions={}
 },
 -- Map-specific streetlamp sites can override the bounded native placement rule.
 lampSites={}
}
