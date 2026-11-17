# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/quiz'

# Заглушка Telegram API: зберігає надіслані повідомлення.
class FakeApi
  attr_reader :sent

  def initialize
    @sent = []
  end

  def send_message(chat_id:, text:, reply_markup: nil)
    @sent << { chat_id: chat_id, text: text, markup: reply_markup }
  end
end

class LoaderTest < Minitest::Test
  def write_json(content)
    file = Tempfile.new(['q', '.json'])
    file.write(content)
    file.close
    file
  end

  def test_loads_real_questions_file
    questions = QuizBot::Loader.load(File.join(__dir__, '..', 'data', 'questions.json'))
    assert_equal 8, questions.size
    assert(questions.all? { |q| q.options.size == 4 })
  end

  def test_missing_file
    assert_raises(QuizBot::QuestionError) { QuizBot::Loader.load('/no/such/file.json') }
  end

  def test_invalid_json
    assert_raises(QuizBot::QuestionError) { QuizBot::Loader.load(write_json('{oops').path) }
  end

  def test_answer_index_out_of_range
    json = '[{"text":"Q","options":["a","b"],"answer":2}]'
    assert_raises(QuizBot::QuestionError) { QuizBot::Loader.load(write_json(json).path) }
  end

  def test_too_few_options
    json = '[{"text":"Q","options":["a"],"answer":0}]'
    assert_raises(QuizBot::QuestionError) { QuizBot::Loader.load(write_json(json).path) }
  end

  def test_empty_array
    assert_raises(QuizBot::QuestionError) { QuizBot::Loader.load(write_json('[]').path) }
  end
end

class HandlerTest < Minitest::Test
  QUESTIONS = [
    QuizBot::Question.new('2+2?', %w[3 4], 1),
    QuizBot::Question.new('Столиця України?', %w[Київ Львів], 0)
  ].freeze

  def setup
    @api = FakeApi.new
    @handler = QuizBot::Handler.new(@api, QUESTIONS, rng: Random.new(1))
  end

  def texts
    @api.sent.map { |m| m[:text] }
  end

  def right_answer_for(text)
    QUESTIONS.find { |q| text.include?(q.text) }.correct_text
  end

  def test_start_greets_by_name
    @handler.handle(1, '/start', first_name: 'Максим')
    assert_includes texts.last, 'Привіт, Максим!'
  end

  def test_unknown_text_without_quiz
    @handler.handle(1, 'щось')
    assert_includes texts.last, 'Я вас не зрозумів'
  end

  def test_quiz_asks_question_with_options_keyboard
    @handler.handle(1, '/quiz')
    assert_includes texts.last, 'Запитання 1 з 2'
    assert_equal 2, @api.sent.last[:markup].size
  end

  def test_full_run_with_all_correct_answers
    @handler.handle(1, '/quiz')
    2.times { @handler.handle(1, right_answer_for(texts.last)) }
    assert_includes texts.last, 'Результат: 2 з 2'
  end

  def test_wrong_answer_shows_right_one_and_scores_zero
    @handler.handle(1, '/quiz')
    q = QUESTIONS.find { |x| texts.last.include?(x.text) }
    wrong = (q.options - [q.correct_text]).first
    @handler.handle(1, wrong)
    assert_includes texts[-2], "Правильна відповідь: #{q.correct_text}"
  end

  def test_text_outside_options_does_not_advance
    @handler.handle(1, '/quiz')
    before = @api.sent.size
    @handler.handle(1, 'не знаю')
    assert_equal before + 1, @api.sent.size
    assert_includes texts.last, 'Оберіть один із варіантів'
    @handler.handle(1, right_answer_for(texts[-2]))
    assert_includes texts[-1], 'Запитання 2 з 2'
  end

  def test_stop_reports_score
    @handler.handle(1, '/quiz')
    @handler.handle(1, '/stop')
    assert_includes texts.last, 'Ваш результат: 0 з 2'
  end

  def test_stop_without_quiz
    @handler.handle(1, '/stop')
    assert_includes texts.last, 'Вікторина не запущена'
  end

  def test_sessions_are_independent_per_chat
    @handler.handle(1, '/quiz')
    @handler.handle(2, '/quiz')
    @handler.handle(1, right_answer_for(texts[-2]))
    @handler.handle(2, '/stop')
    assert_includes texts.last, 'Ваш результат: 0 з 2'
  end

  def test_quiz_restarts_after_finish
    @handler.handle(1, '/quiz')
    2.times { @handler.handle(1, right_answer_for(texts.last)) }
    @handler.handle(1, '/quiz')
    assert_includes texts.last, 'Запитання 1 з 2'
  end
end
