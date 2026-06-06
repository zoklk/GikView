import { UserManager, WebStorageStateStore } from 'oidc-client-ts';

// 나중에 인프라 팀에서 주소를 받으면 아래 변수들을 수정하세요.
const oidcConfig = {
  authority: "https://gist-idp.example.com", // GIST IdP 주소
  client_id: "gikview-client-id",           // 발급받을 클라이언트 ID
  redirect_uri: window.location.origin + "/callback", // 설정할 리다이렉트 URL
  response_type: "code",
  scope: "openid profile email",
  userStore: new WebStorageStateStore({ store: window.localStorage }),
};

const userManager = new UserManager(oidcConfig);

export const authService = {
  // 로그인 페이지로 이동
  login: () => userManager.signinRedirect(),
  
  // 로그인 후 돌아왔을 때 토큰 처리
  handleCallback: () => userManager.signinRedirectCallback(),
  
  // 현재 저장된 사용자 정보(JWT 포함) 가져오기
  getUser: () => userManager.getUser(),
  
  // 로그아웃
  logout: () => userManager.signoutRedirect(),
};