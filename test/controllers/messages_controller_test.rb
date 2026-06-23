require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "can create a message" do
    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "does not create message when assistant is still responding" do
    @chat.messages.create!(type: "AssistantMessage", status: :pending, ai_model: "gpt-4.1")

    assert_no_difference "UserMessage.count" do
      post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }
    end

    assert_redirected_to chat_path(@chat)
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end
end
