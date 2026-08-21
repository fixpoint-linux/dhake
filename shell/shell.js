// shell/shell.js — @mfe/framework thin-shell entry.
//
// Boots a single-route app ('/' -> template 'dhake') and mounts the Elm
// docs MFE into the [data-mfe="dhake-page"] slot of that template.
//
// The page ships statically pre-rendered (see scripts/ssg.mjs): the #app root
// carries an `ssr` attribute, so createApp rehydrates the existing DOM in
// place instead of wiping it and re-fetching the template on first paint.

import { createApp } from '@mfe/framework';

// Works at both the Pages subpath (fixpoint-linux.github.io/dhake/) and the
// domain root. The framework's basePath option scopes route matching to the
// repo subpath: on GitHub Pages the initial pathname is '/dhake/' (or
// '/dhake'), so we derive the first path segment as the base and the root
// route '/' matches after it is stripped. At the domain root the first
// segment is absent, so basePath is '/' and matching is unchanged.
const basePath = (() => {
  const first = window.location.pathname.split('/').filter(Boolean)[0];
  return first ? `/${first}` : '/';
})();

// The SSG output only pre-renders the home route; a deep link/refresh on a
// remote route must do a fresh client render instead of rehydrating the
// pre-rendered home DOM into the wrong route. Compare the (base-stripped)
// pathname against basePath to decide whether we're on the home route.
const isHome =
  (window.location.pathname.replace(/\/+$/, '') || '/') === basePath;

const app = await createApp({
  root: document.getElementById('app'),
  routes: [
    { path: '/', template: 'dhake', name: 'home' },
    { path: '/fixpoint-linux', template: 'fixpoint', name: 'fixpoint' },
  ],
  basePath,
  baseURL: './shell/templates',
  ssr: isHome,
});

// Expose the app handle so the shell/host can inspect or drive it later.
window.__dhakeApp = app;
