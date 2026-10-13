const fs=require('node:fs');
const esbuild=require('/Users/xuxuheng/Documents/CastReader/WebReader/node_modules/esbuild');
const modules=['source-text','cr-bridge'];
const chunks={};
for(const name of modules){
 let src=fs.readFileSync(`WebReader/src/${name}.ts`,'utf8').replace(/^import .*$/gm,'').replace(/^export /gm,'');
 if(name==='cr-bridge')src=src.replace(/^function dbg\(.*$/m,'').replace(/\bmammoth\b/g,'import_mammoth.default').replace(/\bePub\b/g,'src_default');
 chunks[name]=esbuild.transformSync(src,{loader:'ts',target:'es2017',legalComments:'none'}).code.trimEnd().split('\n').map(line=>'  '+line).join('\n')+'\n\n';
}
for(const file of ['CastReader/WebAssets/bundle.js','CastReaderTests/Fixtures/google-books-webreader-xctest.js']){
 let bundle=fs.readFileSync(file,'utf8');
 for(const name of modules){
  const marker=`  // src/${name}.ts\n`;
  const start=bundle.lastIndexOf(marker);
  if(start<0)throw new Error('Missing module '+name);
  const end=bundle.indexOf('\n  // ',start+marker.length);
  if(end<0)throw new Error('Missing following module');
  bundle=bundle.slice(0,start)+marker+chunks[name]+bundle.slice(end+1);
 }
 fs.writeFileSync(file,bundle);
 console.log(file);
}
