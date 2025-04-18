defmodule Pinchflat.FastIndexing.FastIndexingHelpersTest do
  use Pinchflat.DataCase

  import Pinchflat.TasksFixtures
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Tasks
  alias Pinchflat.Settings
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.FastIndexing.FastIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingHelpers

  setup do
    stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
      {:ok, media_attributes_return_fixture()}
    end)

    {:ok, [source: source_fixture()]}
  end

  describe "kickoff_indexing_task/1" do
    test "deletes any existing fast indexing tasks", %{source: source} do
      {:ok, job} = Oban.insert(FastIndexingWorker.new(%{"id" => source.id}))
      task = task_fixture(source_id: source.id, job_id: job.id)

      assert Repo.reload!(task)
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(task) end
    end

    test "kicks off a new fast indexing task", %{source: source} do
      assert {:ok, _} = FastIndexingHelpers.kickoff_indexing_task(source)
      assert [worker] = all_enqueued(worker: FastIndexingWorker)
      assert worker.args["id"] == source.id
    end
  end

  describe "index_and_kickoff_downloads/1" do
    test "enqueues a worker for each new media_id in the source's RSS feed", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker] = all_enqueued(worker: MediaDownloadWorker)
      assert worker.args["id"] == media_item.id
      assert worker.priority == 0
    end

    test "does not enqueue a new worker for the source's media IDs we already know about", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      media_item_fixture(source_id: source.id, media_id: "test_1")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "kicks off a download task for all pending media but at a lower priority", %{source: source} do
      pending_item = media_item_fixture(source_id: source.id, media_filepath: nil)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [worker_1, _worker_2] = all_enqueued(worker: MediaDownloadWorker)
      assert worker_1.args["id"] == pending_item.id
      assert worker_1.priority == 1
    end

    test "returns the found media items", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue a download job if the source does not allow it" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)
      source = source_fixture(%{download_media: false})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "creates a download task record", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      assert [media_item] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      assert [_] = Tasks.list_tasks_for(media_item, "MediaDownloadWorker")
    end

    test "passes the source's download options to the yt-dlp runner", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      expect(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, opts, _ot, _addl_opts ->
        assert {:output, "/tmp/test/media/%(title)S.%(ext)S"} in opts
        assert {:remux_video, "mp4"} in opts
        {:ok, media_attributes_return_fixture()}
      end)

      FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not enqueue a download job if the media item does not match the format rules" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      profile = media_profile_fixture(%{shorts_behaviour: :exclude})
      source = source_fixture(%{media_profile_id: profile.id})

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        output =
          Phoenix.json_library().encode!(%{
            id: "video2",
            title: "Video 2",
            original_url: "https://example.com/shorts/video2",
            live_status: "is_live",
            description: "desc2",
            aspect_ratio: 1.67,
            duration: 345.67,
            upload_date: "20210101"
          })

        {:ok, output}
      end)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "does not blow up if a media item cannot be created", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:ok, "{}"}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not blow up if a media item causes a yt-dlp error", %{source: source} do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, _addl ->
        {:error, "message", 1}
      end)

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when testing cookies" do
    test "sets use_cookies if the source uses cookies" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, true} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :all_operations})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :when_needed})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      stub(YtDlpRunnerMock, :run, fn _url, :get_media_attributes, _opts, _ot, addl ->
        assert {:use_cookies, false} in addl

        {:ok, media_attributes_return_fixture()}
      end)

      source = source_fixture(%{cookie_behaviour: :disabled})

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end

  describe "index_and_kickoff_downloads/1 when testing backends" do
    test "uses the YouTube API if it is enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url, _headers ->
        assert url =~ "https://youtube.googleapis.com/youtube/v3/playlistItems"

        {:ok, "{}"}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "the YouTube API creates records as expected", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers ->
        {:ok, ~s({ "items": [ {"contentDetails": {"videoId": "test_1"}} ] })}
      end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used as a backup if the API fails", %{source: source} do
      expect(HTTPClientMock, :get, fn _url, _headers -> {:error, ""} end)
      expect(HTTPClientMock, :get, fn _url -> {:ok, "<yt:videoId>test_1</yt:videoId>"} end)

      Settings.set(youtube_api_key: "test_key")

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end

    test "RSS is used if the API is not enabled", %{source: source} do
      expect(HTTPClientMock, :get, fn url ->
        assert url =~ "https://www.youtube.com/feeds/videos.xml"

        {:ok, "<yt:videoId>test_1</yt:videoId>"}
      end)

      Settings.set(youtube_api_key: nil)

      assert [%MediaItem{}] = FastIndexingHelpers.index_and_kickoff_downloads(source)
    end
  end
end
