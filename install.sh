#!/bin/bash

# 1. Определяем абсолютный путь к папке, где лежат оба файла
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE}" )" && pwd )"
SCRIPT_NAME="ccheck.sh"
FULL_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

echo "📦 Настройка окружения для $SCRIPT_NAME..."

# 2. Проверяем, существует ли сам скрипт ccpcheck.sh
if [ ! -f "$FULL_PATH" ]; then
    echo "❌ Ошибка: Файл '$SCRIPT_NAME' не найден в папке с установщиком!"
    exit 1
fi

# 3. Делаем ccpcheck.sh исполняемым
chmod +x "$FULL_PATH"

# 4. Проверяем, добавлен ли уже этот путь в ~/.bashrc
if grep -q "export PATH=.*$SCRIPT_DIR" ~/.bashrc; then
    echo "⚠️  Путь к папке уже есть в вашем ~/.bashrc"
else
    # Добавляем путь к папке в конец ~/.bashrc
    echo -e "\n# Путь к утилите ccpcheck.sh\nexport PATH=\"\$PATH:$SCRIPT_DIR\"" >> ~/.bashrc
    echo "✅ Путь успешно добавлен в ~/.bashrc"
fi

echo "--------------------------------------------------------"
echo "🎉 Установка завершена!"
echo "👉 Чтобы начать работу в текущем окне терминала, выполните:"
echo "   source ~/.bashrc"
echo "👉 После этого запускайте утилиту командой: $SCRIPT_NAME"
