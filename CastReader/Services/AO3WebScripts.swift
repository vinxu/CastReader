import Foundation

/// Reads only the currently rendered, authenticated AO3 History page.
/// Selectors follow otwarchive's readings/index and reading_blurb templates.
enum AO3WebScripts {
    static let shelf = #"""
    (() => {
      const url = new URL(location.href);
      if (url.protocol !== 'https:' || !['archiveofourown.org','www.archiveofourown.org'].includes(url.hostname)) return null;
      if (document.querySelector('#tos_prompt')) return null;
      const greeting = document.querySelector('#greeting');
      const logout = greeting?.querySelector('a[href*="/users/logout"]');
      const profile = [...(greeting?.querySelectorAll('a[href]') || [])].map(a => new URL(a.href)).find(u => /^\/users\/[^/]+\/?$/.test(u.pathname));
      if (!logout || !profile || profile.origin !== url.origin) return null;
      const account = decodeURIComponent(profile.pathname.split('/')[2]);
      const isHistory = decodeURIComponent(url.pathname).toLowerCase() === `/users/${account}/readings`.toLowerCase() && !url.searchParams.has('show');
      if (!isHistory) return {account,isHistory:false,books:[],nextURL:null};
      // Require the Rails view identity even for an empty/disabled History.
      if (!document.querySelector('#main.readings-index, body.readings-index, #main .reading.work.index')) return null;
      const seen = new Set();
      const books = [...document.querySelectorAll('ol.reading.work.index > li')].flatMap(row => {
        const a = row.querySelector('h4.heading a[href^="/works/"]');
        if (!a) return [];
        const link = new URL(a.href), match = link.pathname.match(/^\/works\/(\d+)$/);
        if (!match || link.origin !== url.origin || seen.has(match[1])) return [];
        seen.add(match[1]);
        return [{workID:match[1], title:a.textContent.trim(), author:[...row.querySelectorAll('a[rel="author"]')].map(a=>a.textContent.trim()).join(', '), account, chapterCount:row.querySelector('dd.chapters')?.textContent.trim() || '', readerURL:link.origin+link.pathname}];
      });
      const page = Number(url.searchParams.get('page') || 1);
      const candidates = [...document.querySelectorAll('.pagination a[href], nav.pagy a[href]')]
        .map(a => new URL(a.href)).filter(u => u.origin === url.origin && u.pathname === url.pathname
          && !u.searchParams.has('show') && Number(u.searchParams.get('page')) > page)
        .sort((a,b) => Number(a.searchParams.get('page')) - Number(b.searchParams.get('page')));
      const next = candidates[0];
      return {account,isHistory,books,nextURL:next?.href || null};
    })()
    """#
}
