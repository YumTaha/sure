class SpendingDigestMailer < ApplicationMailer
  def daily
    @user = params[:user]
    @digest = params[:digest]
    mail(
      to: @user.email,
      subject: t("spending_digest_mailer.daily.subject", amount: @digest.yesterday_total.format)
    )
  end
end
