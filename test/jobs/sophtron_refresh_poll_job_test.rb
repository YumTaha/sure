require "test_helper"

class SophtronRefreshPollJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.sophtron_items.create!(
      name: "Sophtron",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      customer_id: "cust-1",
      user_institution_id: "ui-1"
    )
    @account = accounts(:depository)
    @sophtron_account = @item.sophtron_accounts.create!(
      account_id: "acct-1",
      name: "Checking",
      currency: "USD",
      balance: 100,
      raw_transactions_payload: [ { id: "existing-tx" } ]
    )
    AccountProvider.create!(account: @account, provider: @sophtron_account)
  end

  test "re-enqueues while Sophtron refresh job is still running" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Started" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)

    assert_enqueued_with(job: SophtronRefreshPollJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job", attempts_remaining: 2)
    end
  end

  test "imports transactions and schedules account sync when refresh completes" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 1 })
    SophtronAccount::Processor.any_instance.expects(:process).returns({ transactions_imported: 1 })

    assert_enqueued_with(job: SyncJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job")
    end
  end

  # Sophtron vendor lag: job reports ready but transactions are not yet materialized.
  # When the fetch returns 0 and attempts remain, re-enqueue to retry the fetch.
  test "re-enqueues when job is ready but fetch returns 0 transactions and attempts remain" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "AccountsReady" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 0 })
    SophtronAccount::Processor.any_instance.expects(:process).never

    assert_enqueued_with(job: SophtronRefreshPollJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job", attempts_remaining: 5)
    end
  end

  test "proceeds with Processor and sync when fetch returns non-zero transactions" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "AccountsReady" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 3 })
    SophtronAccount::Processor.any_instance.expects(:process).returns({ transactions_imported: 3 })

    # Should NOT re-enqueue the poll job; SHOULD enqueue a SyncJob for the account
    assert_enqueued_with(job: SyncJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job", attempts_remaining: 5)
    end
  end

  test "successful import clears last_connection_error and restores good status" do
    @item.update!(status: :requires_update, last_connection_error: "Sophtron refresh requires MFA")
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "Completed" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 2 })
    SophtronAccount::Processor.any_instance.expects(:process).returns({ transactions_imported: 2 })

    SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job")

    @item.reload
    assert_nil @item.last_connection_error
    assert_equal "good", @item.status
  end

  test "does not re-enqueue when fetch returns 0 transactions and last attempt is exhausted" do
    provider = mock
    provider.expects(:get_job_information).with("refresh-job").returns({ LastStatus: "AccountsReady" })
    SophtronItem.any_instance.stubs(:sophtron_provider).returns(provider)
    SophtronItem::Importer.any_instance.expects(:import_transactions_after_refresh)
                           .with(@sophtron_account)
                           .returns({ success: true, transactions_count: 0 })
    # Processor runs even on genuinely empty (attempts exhausted) — the account may simply have no txns
    SophtronAccount::Processor.any_instance.expects(:process).returns({})

    assert_no_enqueued_jobs(only: SophtronRefreshPollJob) do
      SophtronRefreshPollJob.perform_now(@sophtron_account, job_id: "refresh-job", attempts_remaining: 1)
    end
  end
end
