import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

// PKCE public client. client_secret 없이 프론트가 전체 인증 흐름 처리.
// VITE_CLIENT_ID / VITE_REDIRECT_URI / VITE_WS_URL 은 CI(frontend.yml)가 환경별 주입.
const userManager = new UserManager({
  authority: 'https://account.gistory.me',
  metadataUrl: 'https://api.account.gistory.me/.well-known/openid-configuration',
  client_id: import.meta.env.VITE_CLIENT_ID,
  redirect_uri: import.meta.env.VITE_REDIRECT_URI,
  response_type: 'code',
  // openid 미요청 → id_token 안 받음. WS authorizer 가 access_token 으로 userinfo
  // 검증만 하므로 id_token/profile 불필요. PII 토큰을 브라우저에 안 둠.
  scope: 'email name student_id offline_access',
  // User(access+refresh_token) localStorage 보관 → 새로고침 후 세션 생존.
  // refresh_token XSS 노출은 감수: 이 client scope 가 곧 블래스트 반경(WS 점유율
  // 조회 + userinfo)으로 작고, refresh grant 갱신이라 새로고침 UX 가 우선.
  userStore: new WebStorageStateStore({ store: window.localStorage }),
  automaticSilentRenew: true,
  includeIdTokenInSilentRenew: false,
  accessTokenExpiringNotificationTimeInSeconds: 60,
});

export const authService = {
  // offline_access → refresh_token 발급 위해 consent 강제
  login: () =>
    userManager.signinRedirect({
      prompt: 'consent',
    }),

  handleCallback: () => userManager.signinRedirectCallback(),
  getUser: () => userManager.getUser(),
  signinSilent: () => userManager.signinSilent(),
  logout: () => userManager.removeUser(),
};
