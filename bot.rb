# frozen_string_literal: true

require 'telegram/bot'
# Шляхи відносно поточної папки, а не через __dir__: у консолі з кодуванням
# 866 Ruby псує кирилицю в абсолютному шляху (напр. «універ»). Тому бота
# запускають із папки проєкту.
require './lib/quiz'

# Токен береться зі змінної середовища або з файлу .env (він у .gitignore,
# тому не потрапляє до Git).
env_file = '.env'
if File.exist?(env_file)
  File.foreach(env_file, encoding: 'utf-8') do |line|
    key, value = line.strip.split('=', 2)
    next if key.nil? || key.start_with?('#') || value.nil?

    ENV[key] ||= value.strip.delete('"\'')
  end
end

token = ENV['TELEGRAM_BOT_TOKEN']
abort('Задайте змінну середовища TELEGRAM_BOT_TOKEN (токен від @BotFather).') if token.to_s.empty?

begin
  questions = QuizBot::Loader.load(File.join('data', 'questions.json'))
rescue QuizBot::QuestionError => e
  abort("Помилка запитань: #{e.message}")
end

# Клавіатура з варіантами відповідей: по одному варіанту в рядку.
keyboard = lambda do |options|
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: options.map { |o| [o] }, one_time_keyboard: true, resize_keyboard: true
  )
end

Telegram::Bot::Client.run(token) do |bot|
  handler = QuizBot::Handler.new(bot.api, questions, keyboard: keyboard)
  puts 'Бот запущено. Для зупинки натисніть Ctrl+C.'

  bot.listen do |message|
    next unless message.respond_to?(:text) && message.text

    begin
      handler.handle(message.chat.id, message.text, first_name: message.from&.first_name)
    rescue StandardError => e
      # Одна помилка не повинна зупиняти бота для інших користувачів.
      warn "Помилка обробки повідомлення: #{e.class}: #{e.message}"
      bot.api.send_message(chat_id: message.chat.id, text: 'Сталася помилка. Спробуйте ще раз.')
    end
  end
end
