# janarym_app2

## Setup Android

- Install Android SDK Platform 36 (`platforms;android-36`) and build-tools.
- Use JDK 17.
- Run `flutter doctor` and ensure Android toolchain is green.

## Setup .env

- Copy `.env.example` to `.env`.
- Fill `OPENAI_API_KEY` (required) and `YOLO_SERVER_URL` (optional).
- Run with the env file passed at build time:
  `flutter run --dart-define-from-file=.env`
- If `.env` is missing or the key is empty, the app will show:
  "Нет .env, добавь OPENAI_API_KEY".
