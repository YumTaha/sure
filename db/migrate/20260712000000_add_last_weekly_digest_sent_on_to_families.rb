class AddLastWeeklyDigestSentOnToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :last_weekly_digest_sent_on, :date
  end
end
