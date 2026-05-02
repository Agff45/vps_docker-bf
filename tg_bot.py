#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Telegram Docker 备份机器人
支持查看备份状态、手动触发备份
"""

import json
import os
import asyncio
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

# ================= 配置区域 =================
BOT_TOKEN = "你的BotToken"
ALLOWED_CHAT_ID = 你的ChatID

STATUS_FILE = "/root/bf/backup_status.json"
BACKUP_SCRIPT = "/root/bf/bf.sh"
# ===========================================

is_backing_up = False


def is_authorized(update: Update) -> bool:
    return update.effective_chat.id == ALLOWED_CHAT_ID


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        await update.message.reply_text("⛔ 无权限访问此机器人")
        return

    welcome_msg = """🤖 <b>Docker 备份机器人</b>

欢迎使用 Docker 备份管理机器人！

<b>可用命令：</b>
/status - 查看最近备份状态
/run - 手动触发 Docker 备份
/help - 显示帮助信息"""

    await update.message.reply_text(welcome_msg, parse_mode='HTML')


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        await update.message.reply_text("⛔ 无权限访问此机器人")
        return

    help_msg = """📖 <b>帮助信息</b>

<b>命令列表：</b>

/start - 显示欢迎消息
/status - 查看最近一次备份的详细状态
/run - 手动触发 Docker 容器备份
/help - 显示此帮助信息

<b>备份内容：</b>
• 所有运行中的 Docker 容器 (docker inspect)
• docker-compose 项目 (含 compose 文件)
• 普通容器的卷数据和运行参数
• /home/docker 下的文件"""
    await update.message.reply_text(help_msg, parse_mode='HTML')


async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        await update.message.reply_text("⛔ 无权限访问此机器人")
        return

    if not os.path.exists(STATUS_FILE):
        await update.message.reply_text("📭 暂无备份记录\n\n使用 /run 命令执行首次备份")
        return

    try:
        with open(STATUS_FILE, 'r', encoding='utf-8') as f:
            s = json.load(f)

        last_run = datetime.strptime(s['last_run'], '%Y-%m-%d %H:%M:%S')
        time_diff = datetime.now() - last_run
        hours_ago = int(time_diff.total_seconds() // 3600)
        minutes_ago = int((time_diff.total_seconds() % 3600) // 60)
        time_ago_str = f"{hours_ago}小时{minutes_ago}分钟前" if hours_ago > 0 else f"{minutes_ago}分钟前"

        duration = s.get('duration_seconds', 0)
        duration_min = duration // 60
        duration_sec = duration % 60

        status_icon = "✅" if s['status'] == 'success' else ("⚪" if s['status'] == 'skipped' else "❌")

        def remote_icon(st):
            return "✅ 成功" if st == 'success' else ("⏭️ 跳过" if st == 'skipped' else "❌ 失败")

        r1 = remote_icon(s.get('remote1_status', 'unknown'))
        r2 = remote_icon(s.get('remote2_status', 'unknown'))

        msg = f"""📊 <b>Docker 备份状态</b>

{status_icon} <b>状态:</b> {s['message']}
📅 <b>时间:</b> {s['last_run']}
⏰ <b>距今:</b> {time_ago_str}

📦 <b>文件:</b> <code>{s.get('file_name', 'N/A')}</code>
📊 <b>大小:</b> {s.get('file_size', 'N/A')}
⏱️ <b>耗时:</b> {duration_min}分{duration_sec}秒

🐳 <b>容器统计:</b>
• 总计: {s.get('containers_total', 'N/A')} 个
• Compose: {s.get('containers_compose', 'N/A')} 个
• 普通: {s.get('containers_normal', 'N/A')} 个
• 跳过: {s.get('containers_skipped', 'N/A')} 个

☁️ <b>网盘上传:</b>
• {s.get('remote1_name', 'onedrive')}: {r1}
• {s.get('remote2_name', 'gdrive')}: {r2}"""

        await update.message.reply_text(msg, parse_mode='HTML')

    except Exception as e:
        await update.message.reply_text(f"⚠️ 读取状态失败: {str(e)}")


async def run_backup(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    global is_backing_up

    if not is_authorized(update):
        await update.message.reply_text("⛔ 无权限访问此机器人")
        return

    if is_backing_up:
        await update.message.reply_text("⚠️ 备份正在进行中，请稍后再试")
        return

    is_backing_up = True

    message = await update.message.reply_text(
        "🚀 <b>Docker 备份已触发</b>\n\n⏳ 正在执行 bf.sh ...", parse_mode='HTML')

    try:
        process = await asyncio.create_subprocess_exec(
            BACKUP_SCRIPT,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT
        )

        output_lines = []
        last_update = 0

        while True:
            line = await process.stdout.readline()
            if not line:
                break
            text = line.decode('utf-8', errors='ignore').strip()
            if text:
                output_lines.append(text)

            current_time = asyncio.get_event_loop().time()
            if current_time - last_update >= 3:
                last_update = current_time
                recent = output_lines[-6:]
                try:
                    await message.edit_text(
                        "🚀 <b>Docker 备份进行中...</b>\n\n<pre>"
                        + "\n".join(recent)
                        + "</pre>",
                        parse_mode='HTML'
                    )
                except Exception:
                    pass

        await process.wait()

        if process.returncode == 0:
            if os.path.exists(STATUS_FILE):
                with open(STATUS_FILE, 'r', encoding='utf-8') as f:
                    s = json.load(f)

                d = s.get('duration_seconds', 0)
                dm = d // 60
                ds = d % 60

                def remote_icon(st):
                    return "✅ 成功" if st == 'success' else ("⏭️ 跳过" if st == 'skipped' else "❌ 失败")

                r1 = remote_icon(s.get('remote1_status', 'unknown'))
                r2 = remote_icon(s.get('remote2_status', 'unknown'))

                final_msg = f"""🎉 <b>Docker 备份完成!</b>

📅 时间: {s.get('last_run', '')}
📦 文件: <code>{s.get('file_name', '')}</code>
📊 大小: {s.get('file_size', '')}
⏱️ 耗时: {dm}分{ds}秒

🐳 <b>容器统计:</b>
• 总计: {s.get('containers_total', '0')} 个
• Compose: {s.get('containers_compose', '0')} 个
• 普通: {s.get('containers_normal', '0')} 个
• 跳过: {s.get('containers_skipped', '0')} 个

☁️ <b>上传状态:</b>
• {s.get('remote1_name', 'onedrive')}: {r1}
• {s.get('remote2_name', 'gdrive')}: {r2}"""

                await message.edit_text(final_msg, parse_mode='HTML')
            else:
                await message.edit_text("✅ <b>Docker 备份完成!</b>", parse_mode='HTML')
        else:
            await message.edit_text(
                f"❌ <b>Docker 备份失败</b>\n\n退出码: {process.returncode}\n\n"
                f"<pre>{chr(10).join(output_lines[-10:])}</pre>",
                parse_mode='HTML')

    except Exception as e:
        await message.edit_text(f"❌ <b>备份执行异常</b>\n\n{str(e)}", parse_mode='HTML')
    finally:
        is_backing_up = False


def main() -> None:
    print("🤖 正在启动 Telegram Docker 备份机器人...")

    application = Application.builder().token(BOT_TOKEN).build()

    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("status", status))
    application.add_handler(CommandHandler("run", run_backup))

    print("✅ 机器人已启动，等待命令...")

    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == '__main__':
    main()
