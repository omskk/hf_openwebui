#!/bin/bash
# 注意：确保脚本执行时系统中已安装 date、git、curl 等工具，并设置好 TZ 时区环境（可在每个 date 命令中临时指定时区）

# 检查必要的环境变量
if [ -z "$G_NAME" ] || [ -z "$G_TOKEN" ]; then
    echo "缺少必要的环境变量 G_NAME 或 G_TOKEN"
    exit 1
fi

# 解析仓库名和用户名
IFS='/' read -r GITHUB_USER GITHUB_REPO <<< "$G_NAME"

# 构建 GitHub 仓库的克隆 URL，包含令牌
REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"
mkdir -p  ./data/github_data

# 克隆仓库
echo "正在克隆仓库……"
git clone "$REPO_URL" ./data/github_data || {
    echo "克隆失败，请检查 G_NAME 和 G_TOKEN 是否正确。"
    exit 1
}

if [ -f ./data/github_data/webui.db ]; then
    cp ./data/github_data/webui.db ./data/webui.db
    echo "从 GitHub 仓库中拉取成功"
else
    echo "GitHub 仓库中未找到 webui.db，将在同步时推送"
fi

# 定义同步函数，按照北京时间 08:00～24:00（包含整点同步）的要求
sync_data() {
    while true; do
        # 使用 Asia/Shanghai 时区获取当前时间及其组成部分
        CURRENT_TS=$(TZ=Asia/Shanghai date +%s)
        CURRENT_DATE=$(TZ=Asia/Shanghai date '+%Y-%m-%d')
        CURRENT_HOUR=$(TZ=Asia/Shanghai date +%H)  # 00~23
        CURRENT_MIN=$(TZ=Asia/Shanghai date +%M)
        CURRENT_SEC=$(TZ=Asia/Shanghai date +%S)
        
        # 计算下一次同步的目标时间戳（北京时间）
        # 如果当前时间早于 08:00，则目标为今天 08:00
        if [ "$CURRENT_HOUR" -lt 8 ]; then
            TARGET_TS=$(TZ=Asia/Shanghai date -d "${CURRENT_DATE} 08:00:00" +%s)
        # 如果在 08:00 至 22:59，则下一个整点在当日
        elif [ "$CURRENT_HOUR" -ge 8 ] && [ "$CURRENT_HOUR" -lt 23 ]; then
            # 如果正好在整点（秒与分都为 0）则立刻同步
            if [ "$CURRENT_MIN" -eq 0 ] && [ "$CURRENT_SEC" -eq 0 ]; then
                TARGET_TS=$CURRENT_TS
            else
                NEXT_HOUR=$((10#$CURRENT_HOUR + 1))
                TARGET_TS=$(TZ=Asia/Shanghai date -d "${CURRENT_DATE} ${NEXT_HOUR}:00:00" +%s)
            fi
        # 如果当前时间处于 23:00~23:59，则下次目标为次日 00:00（也就是24:00同步）
        else  # CURRENT_HOUR == 23
            if [ "$CURRENT_MIN" -eq 0 ] && [ "$CURRENT_SEC" -eq 0 ]; then
                TARGET_TS=$CURRENT_TS
            else
                TOMORROW=$(TZ=Asia/Shanghai date -d "tomorrow" '+%Y-%m-%d')
                TARGET_TS=$(TZ=Asia/Shanghai date -d "${TOMORROW} 00:00:00" +%s)
            fi
        fi

        # 计算等待时间（若正好同步时则 sleep_time 为 0）
        SLEEP_TIME=$(( TARGET_TS - CURRENT_TS ))
        if [ "$SLEEP_TIME" -gt 0 ]; then
            echo "距离下一次同步还有 ${SLEEP_TIME} 秒（北京时间下次同步时间为 $(TZ=Asia/Shanghai date -d "@$TARGET_TS" '+%Y-%m-%d %H:%M:%S')）"
            sleep "$SLEEP_TIME"
        fi

        # 同步时输出当前北京时间
        CURRENT_TIME=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
        echo "当前时间 $CURRENT_TIME"

        # ---- 开始同步流程 ----

        # 1. 同步到 GitHub
        echo "开始执行 GitHub 同步……"
        cd ./data/github_data || { echo "切换目录失败"; exit 1; }
        git config user.name "AutoSync Bot"
        git config user.email "autosync@bot.com"

        # 确保在 main 分支，如切换失败则尝试 master 分支
        git checkout main 2>/dev/null || git checkout master

        # 将最新数据库文件复制到仓库目录下
        if [ -f "../webui.db" ]; then  
            cp ../webui.db ./webui.db  
        else  
            echo "数据库尚未初始化"
        fi 

        # 检查是否有变化
        if [[ -n $(git status -s) ]]; then
            git add webui.db
            git commit -m "Auto sync webui.db $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')"
            git push origin HEAD && {
                echo "GitHub 推送成功"
            } || {
                echo "推送失败，等待重试..."
                sleep 10
                git push origin HEAD || {
                    echo "重试失败，放弃推送到 GitHub。"
                }
            }
        else
            echo "GitHub：没有检测到数据库变化"
        fi
        # 返回主目录
        cd ../..

        # 2. 同步到 WebDAV（若环境变量配置完整）
        if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USERNAME" ] || [ -z "$WEBDAV_PASSWORD" ]; then
            echo "WebDAV 环境变量缺失，跳过 WebDAV 同步。"
        else
            echo "开始执行 WebDAV 同步……"
            FILENAME="webui_$(TZ=Asia/Shanghai date +'%m_%d').db"
            if [ -f ./data/webui.db ]; then
                curl -T ./data/webui.db --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME" && {
                    echo "WebDAV 上传成功"
                } || {
                    echo "WebDAV 上传失败，等待重试..."
                    sleep 10
                    curl -T ./data/webui.db --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME" || {
                        echo "重试失败，放弃 WebDAV 上传。"
                    }
                }
            else
                echo "未找到 webui.db 文件，跳过 WebDAV 同步。"
            fi
        fi

        # ---- 同步流程结束，下一轮循环会根据当前北京时间自动计算等待时长 ----

    done
}

# 后台启动同步进程
sync_data &