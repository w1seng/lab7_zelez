# frozen_string_literal: true

require 'json'

# Логіка вікторини без залежності від Telegram: її легко перевіряти тестами.
module QuizBot
  class QuestionError < StandardError; end

  # Одне запитання: текст, варіанти відповідей, індекс правильної відповіді.
  Question = Struct.new(:text, :options, :answer) do
    def correct?(choice)
      options[answer] == choice
    end

    def correct_text
      options[answer]
    end
  end

  # Читає та перевіряє запитання з JSON-файлу.
  module Loader
    module_function

    def load(path)
      raw = JSON.parse(File.read(path))
      raise QuestionError, 'Файл запитань має бути масивом' unless raw.is_a?(Array)
      raise QuestionError, 'Файл запитань порожній' if raw.empty?

      raw.each_with_index.map { |item, i| build(item, i + 1) }
    rescue Errno::ENOENT
      raise QuestionError, "Файл запитань не знайдено: #{path}"
    rescue JSON::ParserError => e
      raise QuestionError, "Некоректний JSON: #{e.message}"
    end

    def build(item, number)
      text = item['text'].to_s.strip
      options = item['options']
      answer = item['answer']
      raise QuestionError, "Запитання #{number}: порожній текст" if text.empty?
      unless options.is_a?(Array) && options.size >= 2 && options.all? { |o| o.is_a?(String) && !o.strip.empty? }
        raise QuestionError, "Запитання #{number}: потрібно щонайменше 2 непорожні варіанти"
      end
      unless answer.is_a?(Integer) && answer.between?(0, options.size - 1)
        raise QuestionError, "Запитання #{number}: індекс правильної відповіді поза межами"
      end

      Question.new(text, options, answer)
    end
  end

  # Стан вікторини одного користувача (чату).
  class Session
    attr_reader :score, :index

    def initialize(questions, rng: Random.new)
      @questions = questions.shuffle(random: rng)
      @index = 0
      @score = 0
    end

    def total
      @questions.size
    end

    def finished?
      @index >= total
    end

    def current
      @questions[@index]
    end

    # Приймає текст відповіді. Повертає nil, якщо це не один із варіантів.
    # Інакше повертає хеш { correct:, right_answer: } і переходить далі.
    def answer(choice)
      return nil if finished?

      question = current
      return nil unless question.options.include?(choice)

      correct = question.correct?(choice)
      @score += 1 if correct
      @index += 1
      { correct: correct, right_answer: question.correct_text }
    end
  end

  # Обробляє повідомлення. api — будь-який об'єкт з методом
  # send_message(chat_id:, text:, reply_markup:), що дозволяє підставити заглушку в тестах.
  class Handler
    def initialize(api, questions, rng: Random.new, keyboard: nil)
      @api = api
      @questions = questions
      @rng = rng
      @keyboard = keyboard || ->(options) { options }
      @sessions = {}
    end

    def handle(chat_id, text, first_name: nil)
      text = text.to_s.strip
      case text
      when '/start' then start(chat_id, first_name)
      when '/quiz' then begin_quiz(chat_id)
      when '/stop' then stop(chat_id)
      when '/help' then say(chat_id, help_text)
      else answer(chat_id, text)
      end
    end

    private

    def start(chat_id, first_name)
      name = first_name.to_s.empty? ? '' : ", #{first_name}"
      say(chat_id, "Привіт#{name}! Я бот-вікторина про мандрівки Україною.\n#{help_text}")
    end

    def help_text
      "Команди:\n/quiz — почати вікторину\n/stop — завершити вікторину\n/help — допомога"
    end

    def begin_quiz(chat_id)
      @sessions[chat_id] = Session.new(@questions, rng: @rng)
      ask(chat_id)
    end

    def stop(chat_id)
      session = @sessions.delete(chat_id)
      if session
        say(chat_id, "Вікторину завершено. Ваш результат: #{session.score} з #{session.total}.")
      else
        say(chat_id, 'Вікторина не запущена. Напишіть /quiz.')
      end
    end

    def answer(chat_id, text)
      session = @sessions[chat_id]
      return say(chat_id, 'Я вас не зрозумів. Напишіть /quiz, щоб почати, або /help.') unless session

      result = session.answer(text)
      return say(chat_id, 'Оберіть один із варіантів відповіді на клавіатурі або напишіть /stop.') unless result

      say(chat_id, result[:correct] ? '✅ Правильно!' : "❌ Неправильно. Правильна відповідь: #{result[:right_answer]}")
      if session.finished?
        @sessions.delete(chat_id)
        say(chat_id, "Вікторину завершено! Результат: #{session.score} з #{session.total}. Напишіть /quiz, щоб спробувати ще раз.")
      else
        ask(chat_id)
      end
    end

    def ask(chat_id)
      session = @sessions[chat_id]
      question = session.current
      say(chat_id, "Запитання #{session.index + 1} з #{session.total}:\n#{question.text}", @keyboard.call(question.options))
    end

    def say(chat_id, text, markup = nil)
      @api.send_message(chat_id: chat_id, text: text, reply_markup: markup)
    end
  end
end
