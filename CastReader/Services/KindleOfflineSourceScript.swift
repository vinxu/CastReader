import Foundation

/// Observes the reader's own render responses. It never changes request
/// authentication, encryption parameters, or the renderer's response body.
enum KindleOfflineSourceScript {
    static let bootstrap = #"""
    (() => {
      if(window.__crOfflineSourceVersion===1)return;
      window.__crOfflineSourceVersion=1;
      const state={metadata:null,asin:'',revision:'',layout:null,pages:new Map()};
      const layoutKeys=['asin','revision','contentType','dpi','fontFamily','fontSize','height','lineHeight','marginBottom','marginLeft','marginRight','marginTop','maxNumberColumns','rasterScale','theme','version','width'];
      function parse(buffer) {
        const bytes=new Uint8Array(buffer), decoder=new TextDecoder(), files=[];
        if(bytes.length>32*1024*1024)throw new Error('oversized-render');
        for(let offset=0,count=0;offset+512<=bytes.length&&count<200;count++) {
          const name=decoder.decode(bytes.subarray(offset,offset+100)).replace(/\0.*$/,'');
          if(!name)break;
          const size=parseInt(decoder.decode(bytes.subarray(offset+124,offset+136)).replace(/\0.*$/,'').trim(),8);
          if(!Number.isSafeInteger(size)||size<0||size>16*1024*1024||offset+512+size>bytes.length)throw new Error('invalid-render');
          if(/^(metadata|manifest|page_data[^/]*)\.json$/.test(name)) {
            files.push({name,value:JSON.parse(decoder.decode(bytes.subarray(offset+512,offset+512+size)))});
          }
          offset+=512+Math.ceil(size/512)*512;
        }
        return files;
      }
      async function parameters(input, options) {
        const url=new URL(input instanceof Request?input.url:String(input),location.href);
        let values=Object.fromEntries(url.searchParams);
        let body=options?.body;
        if(input instanceof Request&&!body&&input.method!=='GET')body=await input.clone().text();
        if(typeof body==='string') {
          try {values={...values,...JSON.parse(body)};}catch(_){values={...values,...Object.fromEntries(new URLSearchParams(body))};}
        }
        const layout={};
        for(const key of layoutKeys) if(['string','number'].includes(typeof values[key]))layout[key]=String(values[key]);
        return layout;
      }
      const original=window.fetch;
      window.fetch=async function(input,options) {
        const url=input instanceof Request?input.url:String(input||'');
        const relevant=url.includes('/renderer/render');
        const requestLayout=relevant?parameters(input,options):null;
        const response=await original.apply(this,arguments);
        if(relevant&&response.ok) {
          const copy=response.clone();
          Promise.all([copy.arrayBuffer(),requestLayout]).then(([buffer,layout])=>{
            const files=parse(buffer);
            const metadata=files.find(f=>f.name==='metadata.json')?.value;
            const manifest=files.find(f=>f.name==='manifest.json')?.value;
            if(!metadata||!manifest||typeof manifest.asin!=='string'||typeof manifest.revision!=='string')return;
            if(!Number.isSafeInteger(metadata.firstPositionId)||!Number.isSafeInteger(metadata.lastPositionId))return;
            const layoutString=JSON.stringify(layout);
            if(state.asin!==manifest.asin||state.revision!==manifest.revision||JSON.stringify(state.layout)!==layoutString)state.pages.clear();
            state.asin=manifest.asin;state.revision=manifest.revision;state.layout=layout;state.metadata={minimum:metadata.firstPositionId,maximum:metadata.lastPositionId,cover:metadata.coverPosistion,language:metadata.lang};
            for(const file of files.filter(f=>/^page_data/.test(f.name)&&Array.isArray(f.value))) {
              for(const page of file.value) {
                if(Number.isSafeInteger(page.startPositionId)&&Number.isSafeInteger(page.endPositionId)) {
                  state.pages.set(page.startPositionId,{start:page.startPositionId,end:page.endPositionId,words:page.wordsInPage,index:page.pageIndex,width:page.width,height:page.height});
                }
              }
            }
            // Only transient source evidence is bounded. Saved book pages are
            // committed by native code and have no prefetch-window page limit.
            while(state.pages.size>120)state.pages.delete(state.pages.keys().next().value);
          }).catch(()=>{});
        }
        return response;
      };
      function context() {
        let navigation=null,loading=true;
        for(const node of document.querySelectorAll('#kr-renderer,#kr-chevron-left,#kr-chevron-right,#kr-scrubber-bar')) {
          const key=Object.keys(node).find(k=>/^__react(Fiber|InternalInstance)\$/.test(k));
          let fiber=key&&node[key],root=fiber;
          while(root?.return)root=root.return;
          if(root?.stateNode?.current&&root!==root.stateNode.current)fiber=fiber?.alternate||fiber;
          for(let depth=0;fiber&&depth<64;depth++,fiber=fiber.return) {
            const value=fiber.memoizedProps?.value;
            if(typeof value?.readerState?.isRendererLoading==='boolean')loading=value.readerState.isRendererLoading;
            if(typeof value?.moveToPosition==='function'&&typeof value?.nextPage==='function')navigation=value;
          }
        }
        return {navigation,loading};
      }
      let progressGuard=null;
      window.__crOfflineProgressGuard=(active,asin)=>{
        if(!active) {
          if(progressGuard)progressGuard.active=false;
          return true;
        }
        if(state.asin!==asin)return false;
        if(progressGuard) {progressGuard.active=true;progressGuard.asin=asin;return true;}
        let service=null;
        for(const node of document.querySelectorAll('#kr-renderer,#kr-chevron-left,#kr-chevron-right,#kr-scrubber-bar')) {
          const key=Object.keys(node).find(k=>/^__react(Fiber|InternalInstance)\$/.test(k));
          let fiber=key&&node[key],root=fiber;
          while(root?.return)root=root.return;
          if(root?.stateNode?.current&&root!==root.stateNode.current)fiber=fiber?.alternate||fiber;
          for(let depth=0;fiber&&depth<100;depth++,fiber=fiber.return) {
            let hook=fiber.memoizedState;
            for(let index=0;hook&&index<80;index++,hook=hook.next) {
              const value=Array.isArray(hook.memoizedState)?hook.memoizedState[0]:null;
              if(typeof value?.stillReading==='function'&&typeof value?.doneReading==='function'&&typeof value?.startReading==='function')service=value;
            }
          }
        }
        if(!service)return false;
        const guard={active:true,asin,suppressed:0};
        for(const name of ['stillReading','doneReading']) {
          const original=service[name];
          service[name]=function(payload,...args) {
            // Downloading pages must not mark the entire book as read on the
            // user's other devices. Ordinary reading uses the original service.
            if(guard.active&&payload?.asin===guard.asin) {guard.suppressed++;return Promise.resolve();}
            return original.call(this,payload,...args);
          };
        }
        progressGuard=guard;
        return true;
      };
      window.__crOfflineSourceRead=()=>{
        const c=context(),range=c.navigation?.state?.pagePositionRange;
        return JSON.stringify({asin:state.asin,revision:state.revision,layout:state.layout,metadata:state.metadata,
          current:c.navigation?.state?.currentPosition,start:range?.startPosition,end:range?.endPosition,
          loading:c.loading,page:state.pages.get(range?.startPosition)||null,
          progressGuard:progressGuard?{active:progressGuard.active,suppressed:progressGuard.suppressed}:null});
      };
      window.__crOfflineSourceMove=position=>{
        if(!state.metadata||!Number.isSafeInteger(position)||position<state.metadata.minimum||position>state.metadata.maximum)return false;
        const c=context();if(!c.navigation)return false;c.navigation.moveToPosition(position);return true;
      };
      window.__crOfflineSourceAdvance=(position,previousEnd)=>{
        if(!state.metadata||!Number.isSafeInteger(position)||position<state.metadata.minimum||position>state.metadata.maximum)return false;
        const c=context();if(!c.navigation)return false;
        const range=c.navigation.state?.pagePositionRange;
        if(Number.isSafeInteger(previousEnd)&&range?.endPosition+1===previousEnd&&!c.loading) {
          c.navigation.nextPage();
        } else { c.navigation.moveToPosition(position); }
        return true;
      };
      window.__crOfflineSourceRecover=position=>{
        if(!state.metadata||!Number.isSafeInteger(position)||position<state.metadata.minimum||position>state.metadata.maximum)return false;
        const c=context(),range=c.navigation?.state?.pagePositionRange;
        // A fast nextPage may be ignored while the reader is finishing its
        // prior turn. Only re-seek when it is idle and still before the target.
        if(!c.navigation||c.loading||!Number.isSafeInteger(range?.endPosition)||range.endPosition>=position)return false;
        c.navigation.moveToPosition(position);return true;
      };
    })();
    """#
}
