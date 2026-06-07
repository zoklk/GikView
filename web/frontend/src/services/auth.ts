import {
  UserManager,
  InMemoryWebStorage,
  WebStorageStateStore,
} from 'oidc-client-ts';

// PKCE public client. client_secret 없이 프론트가 전체 인증 흐름 처리.
// VITE_CLIENT_ID / VITE_REDIRECT_URI / VITE_WS_URL 은 CI(frontend.yml)가 환경별 주입.
const userManager = new UserManager({
  authority: 'https://account.gistory.me',
  metadataUrl: 'https://api.account.gistory.me/.well-known/openid-configuration',
  client_id: import.meta.env.VITE_CLIENT_ID,
  redirect_uri: import.meta.env.VITE_REDIRECT_URI,
  response_type: 'code',
  // IdP client 에 등록된 mandatory scope 와 일치해야 함
  scope: 'openid email name student_id offline_access',
  // access_token 인메모리 보관 (XSS 방어). stateStore 는 기본값(sessionStorage)
  // 유지 — OIDC redirect 구간에서 PKCE state 생존 필요
  userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
  automaticSilentRenew: true,
  includeIdTokenInSilentRenew: false,
  accessTokenExpiringNotificationTimeInSeconds: 60,
});

export const authService = {
  // 로그인 페이지로 이동 (openid scope → nonce 필수, offline_access → consent 필요)
  login: () =>
    userManager.signinRedirect({
      nonce: crypto.randomUUID(),
      prompt: 'consent',
    }),

  // redirect 복귀 시 authorization_code → 토큰 교환
  handleCallback: () => userManager.signinRedirectCallback(),

  // 인메모리에 저장된 현재 사용자 (없으면 null)
  getUser: () => userManager.getUser(),

  // 토큰 만료 시 hidden iframe 으로 조용히 재발급
  signinSilent: () => userManager.signinSilent(),

  // 로그아웃 (인메모리 사용자 제거)
  logout: () => userManager.removeUser(),
};
