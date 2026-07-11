class SpendingDigestMailer < ApplicationMailer
  def weekly
    @user = params[:user]
    @digest = params[:digest]
    mail(
      to: @user.email,
      subject: t("spending_digest_mailer.weekly.subject", amount: @digest.estimated_total.format)
    )
  end
end
