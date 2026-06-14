// 배경 연출: 평면도(블루프린트) 그리드 + 브랜드 글로우 2개. fixed 라 스크롤 무관,
// pointer-events-none 라 클릭 투과, 에셋 0. 로그인·메인 공유로 디자인 언어 통일.
// 다크는 표면이 이미 깊어 글로우 투명도 낮춤(과하면 페이지가 들뜸).
export function Backdrop({ grid = true }: { grid?: boolean }) {
  return (
    <div className="pointer-events-none fixed inset-0 z-0 overflow-hidden">
      {grid && <div className="blueprint-grid absolute inset-0" />}
      <div className="absolute -top-44 left-1/2 -translate-x-1/2 h-[44rem] w-[80rem] rounded-full bg-[#2EBFA5]/14 dark:bg-[#2EBFA5]/[0.06] blur-[130px]" />
      <div className="absolute top-[32%] -left-40 h-[34rem] w-[34rem] rounded-full bg-[#1F7A8C]/12 dark:bg-[#1F7A8C]/[0.05] blur-[130px]" />
    </div>
  );
}
