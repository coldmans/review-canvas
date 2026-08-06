# Review Canvas MCP

Review Canvas에 Mermaid 다이어그램을 보내고 MCP 저장소에 있는 검토 표시와 revision을 관리하는 로컬 stdio MCP 서버입니다. 네트워크 서버를 열지 않으며, 모든 데이터는 로컬 JSON 파일에 저장합니다.

## 실행

Node.js 20 이상이 필요합니다.

```bash
npm ci
npm start
```

MCP 클라이언트에는 실행 파일의 절대 경로를 등록합니다.

```json
{
  "mcpServers": {
    "review-canvas": {
      "command": "node",
      "args": ["/absolute/path/to/review-canvas/mcp/bin/review-canvas-mcp.js"]
    }
  }
}
```

## 도구 계약

| 도구 | 입력 | 결과 |
| --- | --- | --- |
| `send_diagram` | `title`, `mermaid`, 선택 `targetDevice` (`any`, `mac`, `ipad`) | `diagramId`, `revisionId`, `status: queued` |
| `list_review_marks` | 선택 `diagramId`, `status`, `type` | 필터에 맞는 검토 표시 목록 |
| `propose_revision` | `diagramId`, `mermaid`, `expectedRevisionId`, 선택 `summary` | 원본을 보존한 새 `proposed` revision |
| `resolve_review_mark` | `diagramId`, `markId`, 선택 `expectedStatus` | `status: resolved` |

검토 표시의 `type`은 `explain`, `change`, `verify`이고, `status`는 `open`, `inProgress`, `resolved`, `dismissed`입니다.

`targetDevice`는 현재 envelope에 남기는 metadata입니다. `ipad`를 지정해도 iPad로 직접 전송되지는 않으며, 모든 envelope는 같은 Mac의 Inbox에 저장됩니다. 앱에서 만든 검토 표시를 MCP `store.json`으로 보내는 bridge도 아직 구현 전이므로, 조회·해결 도구는 MCP 저장소에 이미 존재하는 항목에만 동작합니다.

## 로컬 저장 위치

macOS 기본 디렉터리는 다음과 같습니다.

```text
~/Library/Application Support/Review Canvas/Inbox
```

- `diagram-<UUID>.json`: 앱이 가져가서 `Processed`로 옮길 수 있는 불변 초기 envelope
- `store.json`: revision과 review mark를 보관하는 MCP 내부 상태
- `store.json.lock`: 여러 MCP 프로세스의 동시 변경 손실을 막는 짧은 수명의 잠금 파일

테스트나 별도 설치에서는 절대 경로 환경 변수로 디렉터리를 바꿀 수 있습니다.

```bash
REVIEW_CANVAS_DATA_DIR=/absolute/path/to/inbox npm start
```

상대 경로는 거부합니다. JSON 파일은 같은 디렉터리에 임시 파일을 완전히 기록한 뒤 원자적으로 교체하며, 권한은 소유자 읽기·쓰기(`0600`)로 제한합니다. 서버 시작 시 저장 도중 중단된 임시 envelope만 복구하고, 앱이 정상적으로 `Processed`로 옮긴 파일은 다시 만들지 않습니다. Mermaid source는 UTF-8 기준 1 MiB 이하, 내부 store는 64 MiB 이하만 허용합니다.

## 검증

```bash
npm test
npm run test:coverage
npm audit --omit=dev
```
