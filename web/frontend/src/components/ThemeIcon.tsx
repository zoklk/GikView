// Sun/Moon 인라인 아이콘 (lucide path). 아이콘 한두 개 위해 lucide-react 배럴
// 전체(1500+ 모듈) 끌어오면 prod 번들러 부하 → 인라인으로 대체. App·LoginPage 공유.
export function ThemeIcon({ dark }: { dark: boolean }) {
  return (
    <svg
      width={17} height={17} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round"
    >
      {dark ? (
        <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
      ) : (
        <>
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
        </>
      )}
    </svg>
  );
}
