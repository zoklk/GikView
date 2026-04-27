# 1. React 프로젝트 생성 (Vite 사용)
npm create vite@latest gikview-frontend -- --template react

# 2. 디렉토리 이동 및 패키지 설치
cd gikview-frontend
npm install

# 3. 깃 초기화 및 전달해주신 GitHub 레포지토리 연결
git init
git add .
git commit -m "chore: React 프로젝트 초기 세팅"
git branch -M main
git remote add origin https://github.com/zoklk/GikView.git
git push -u origin main