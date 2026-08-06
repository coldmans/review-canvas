# Design QA — iPad 검토 툴바

## 비교 기준

- Source visual truth: `/var/folders/wc/ssfdn4ws6lg_plhw90574s4r0000gn/T/codex-clipboard-9522b39d-496c-4d01-b170-37d2d15fc026.png`
- Implementation screenshot: `/tmp/review-canvas-live.enySS6/ipad-toolbar-final.png`
- Combined comparison: `/tmp/review-canvas-live.enySS6/ipad-toolbar-comparison.png`
- Viewport: iPad Pro 13-inch (M5), 가로 방향, SwiftUI 네이티브 화면
- Source pixels: 1746 × 2326
- Implementation pixels: 2064 × 2752, native 2x capture
- Normalization: implementation을 1746 × 2326으로 축소한 뒤 source와 가로로 결합
- CSS size / deviceScaleFactor: 네이티브 SwiftUI 화면이므로 해당 없음
- State: 샘플 Mermaid, 검토 0개, 주변 Mac 1대, 100% 확대, 사이드바 표시

## Findings

- P0/P1/P2 차이 없음.
- Fonts and typography: 시스템 글꼴, 굵기, 크기, 한 줄 계층은 유지됐다. 검토 유형의 한글이 세로로 분리되던 문제는 아이콘 전용 표시로 제거했고 접근성 이름은 유지했다.
- Spacing and layout rhythm: 툴바 높이, 좌우 순서, 색상 그룹, 사이드바와 캔버스 비율은 유지됐다. 모든 상단 제어와 오른쪽 확대 버튼이 화면 안에 들어온다.
- Colors and visual tokens: 설명 파랑, 수정 주황, 검토 빨강과 기존 배경·경계선 색상을 그대로 사용한다.
- Image quality and asset fidelity: SF Symbols 기반 아이콘을 사용해 스케일에 따른 흐림이 없다. Mermaid 렌더링 품질과 배치는 변경하지 않았다.
- Copy and content: `열기`, `Mac 1대`, `필기`, 제목, 대기 개수, 확대율은 유지됐다. 아이콘 전용 검토 버튼은 VoiceOver에서 `설명`, `수정`, `검토`로 읽힌다.

## Full-view comparison evidence

결합 이미지의 왼쪽 source에는 세 검토 버튼의 한글이 한 글자씩 세로 줄바꿈되어 있다. 오른쪽 implementation에서는 같은 위치와 의미 색상을 유지하면서 `?`, 연필, `!` 아이콘이 수평으로 정렬되고, 나머지 툴바 항목도 한 줄을 유지한다.

## Focused region comparison evidence

이번 변경의 유일한 대상이 상단 툴바이고 결합 이미지에서 해당 영역의 글자와 아이콘을 원본 크기로 판독할 수 있어 별도 확대 crop은 필요하지 않았다.

## Comparison history

1. Initial — P1: `설명`, `수정`, `검토`가 좁은 버튼 안에서 세로로 분리되어 의미 파악이 느리고 시각적으로 깨져 보였다.
2. Iteration 1 — 검토 유형을 SF Symbols 아이콘으로 교체했다. `/tmp/review-canvas-live.enySS6/ipad-toolbar-fixed.png`에서 검토 버튼은 해결됐지만 `열기`, `Mac 1대`가 줄바꿈되어 결과는 blocked였다.
3. Iteration 2 — 일반 동작 라벨을 한 줄 고정했다. `/tmp/review-canvas-live.enySS6/ipad-toolbar-fixed-2.png`에서 해당 문제는 해결됐지만 제목 보조 문구가 세로로 압축되어 결과는 blocked였다.
4. Iteration 3 — 제목 영역을 한 줄로 제한하고 우선순위를 조정했다. `/tmp/review-canvas-live.enySS6/ipad-toolbar-fixed-3.png`에서 글자 깨짐은 해결됐지만 오른쪽 확대 버튼 일부가 잘려 결과는 blocked였다.
5. Final — 제목의 최소 폭을 줄이고 확대 제어 폭을 보호했다. `/tmp/review-canvas-live.enySS6/ipad-toolbar-final.png`에서 세로 글자 깨짐과 제어 잘림이 모두 사라졌다.

## Implementation checklist

- [x] iPad 검토 유형 버튼을 확장 가능한 시스템 아이콘으로 표시
- [x] 세 버튼의 접근성 이름과 힌트 유지
- [x] 나머지 툴바 라벨을 한 줄로 유지
- [x] 제목과 검토 개수의 세로 줄바꿈 방지
- [x] 확대·축소 제어가 화면 밖으로 잘리지 않도록 폭 보호
- [x] 동일 기기·상태에서 다시 캡처하고 source와 결합 비교

## Follow-up polish

- P3: 더 좁은 Split View 폭에서는 보조 제목을 자동으로 숨기는 별도 compact toolbar 변형을 추후 고려할 수 있다.

final result: passed
