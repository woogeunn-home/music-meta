# music-meta

MP3 파일의 메타데이터를 공개 메타데이터 소스에서 찾아 채우고, 필요하면 파일 이름까지 정리하는 앱입니다.

현재 기본 소스는 인증/등록이 필요 없는 조합입니다.

- MusicBrainz: 곡, 아티스트, 앨범, 트랙 번호 등 메타데이터
- Cover Art Archive: MusicBrainz 릴리즈 커버 이미지
- iTunes Search API: MusicBrainz 결과가 부족할 때 보조 검색과 커버 이미지

## 준비

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[gui]"
cp .env.example .env
```

`.env`는 필수가 아닙니다. 국가별 iTunes 결과를 조정하고 싶을 때만 바꾸면 됩니다.

```bash
MUSIC_META_COUNTRY=KR
MUSIC_META_USER_AGENT=music-meta/0.1.0
```

## GUI 사용

네이티브 macOS 앱은 Xcode 프로젝트로도 들어 있습니다.

```bash
open MusicMetaApp.xcodeproj
```

또는 빌드된 앱을 바로 실행할 수 있습니다.

```bash
open dist/MusicMeta.app
```

배포용 zip은 여기 생성됩니다.

```bash
dist/MusicMeta-0.1.0-macOS.zip
```

앱을 다시 빌드하려면:

```bash
xcodebuild -project MusicMetaApp.xcodeproj -scheme MusicMeta -configuration Release -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
cp -R .derivedData/Build/Products/Release/MusicMeta.app dist/
ditto -c -k --keepParent dist/MusicMeta.app dist/MusicMeta-0.1.0-macOS.zip
```

Python/Tk 프로토타입도 남아 있습니다.

```bash
music-meta-app
```

흐름:

1. 앱 실행
2. MP3 파일이나 폴더를 드래그해서 드롭
3. 자동 분석 후 적용될 메타데이터 프리뷰 확인
4. 결과가 마음에 들지 않는 파일은 `재검색`으로 검색어를 수정하고 후보 중 하나를 선택
5. `저장` 클릭 시 기본은 MP3 메타데이터만 덮어쓰기
6. `Advanced: 파일명 변경`을 켜면 패턴에 맞춰 파일명도 변경

파일명 패턴 예시:

```bash
{artist} - {title}
{track} {title}
{album_artist}/{album}/{track} - {title}
```

## CLI 사용

먼저 dry run으로 어떤 변경이 일어날지 확인합니다.

```bash
music-meta ./mp3-folder --dry-run --cover-art
```

괜찮으면 실제로 태그와 파일명을 바꿉니다.

```bash
music-meta ./mp3-folder --yes --cover-art
```

주요 옵션:

```bash
music-meta ./mp3-folder --country US --recursive --cover-art --pattern "{artist} - {title}"
```

- `--country`: iTunes Search API 국가 코드. 기본값은 `MUSIC_META_COUNTRY` 또는 `KR`
- `--recursive`: 하위 폴더까지 처리
- `--cover-art`: 앨범 아트를 MP3에 저장
- `--pattern`: 확장자를 제외한 새 파일명 패턴
- `--dry-run`: 파일을 건드리지 않고 결과만 출력
- `--yes`: 확인 질문 없이 적용

## 참고

- MusicBrainz Search API: https://musicbrainz.org/doc/MusicBrainz_API/Search
- Cover Art Archive API: https://musicbrainz.org/doc/Cover_Art_Archive/API
- iTunes Search API: https://performance-partners.apple.com/search-api

## 테스트

```bash
pip install -e ".[dev]"
pytest
```
