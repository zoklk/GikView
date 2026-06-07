import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react-swc'; // 🚨 패키지명 수정 완료
import tsconfigPaths from 'vite-tsconfig-paths';
import tailwindcss from '@tailwindcss/vite';

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tsconfigPaths(), tailwindcss()],
});