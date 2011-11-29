# -*- coding: utf-8 -*-
# requrie 'date'
require 'net/http'
require 'cgi'
require 'uri'
require 'json'
require 'kconv'
miquire :core, "serialthread"
miquire :addon, "settings"

Plugin::create(:urlsave) do
    settings("URLsave") do
        settings('基本設定') do
            boolean('URLsave起動', :urlsave_on)
            settings('Instapaper') do
                input('ユーザー名', :urlsave_user)
                inputpass('パスワード', :urlsave_pass)
            end
            settings('Read it Later') do
                input('ユーザー名', :urlsave_ril_user)
                inputpass('パスワード', :urlsave_ril_pass)
            end
        end
        settings("無視するURL") do
            multitext('無視するURL', :urlsave_ignore).
                tooltip('1行に一つrubyの正規表現で書く')
        end
    end

    URLSAVE_RIL_API_KEY = 'c34p3R61A6d5ee19bTg4fI1UbydIzi87'
    @thread = SerialThreadGroup.new
    @https = Net::HTTP.new('www.instapaper.com', 443)
    @https.use_ssl = true
    @https_ril = Net::HTTP.new('readitlaterlist.com', 443)
    @https_ril.use_ssl = true
    @urls_ril = []
    onupdate do |service, message|
        @thread.new { instapaper(message) if UserConfig[:urlsave_on]}
    end

    onperiod do |service|
        call_ril_api()
    end

    def instapaper(msg)
        if !msg.empty?
            msg.each do |m|
                get_urls_hash(m).each do |u|
                    add_url(u)
                end
            end
        end
    end

    # Messageに含まれるURLの配列
    def get_urls_hash(msg)
        # 最新のツイートidが設定されていない場合
        if !UserConfig[:urlsave_latest_id].to_i
            UserConfig[:urlsave_latest_id] = msg[:id].to_i
        end
        result = []
        if msg[:id].to_i > UserConfig[:urlsave_latest_id].to_i && !msg.from_me?
            UserConfig[:urlsave_latest_id] = msg[:id].to_i
            entity = msg[:entities]
            entity[:urls].each do |urls|
                tmp = {"id" => msg[:id], "message" => msg.body, "url" => urls[:expanded_url]}
                result << tmp
            end
        end
        result
    end

    # URLを追加する
    def add_url(url_hash)
        url = ignore?(url_hash["url"])
        if url != true
            title = get_title(url)
            call_insta_api(url_hash["id"], url_hash["message"], url, title) if !UserConfig[:urlsave_user].empty?
            add_url_ril(url_hash["id"], url, title) if !UserConfig[:urlsave_ril_user].empty?
        end
    end

    # InstapaperAPI呼び出し
    def call_insta_api(id, message, url, title)
        prm = "username=" + UserConfig[:urlsave_user] + "&url=" + CGI.escape(url) +
            "&selection=" + CGI.escape(message)
        prm = prm + "&title=" + CGI.escape(title) if title != nil
        prm = prm + "&password=" + UserConfig[:urlsave_pass] if !UserConfig[:urlsave_pass].empty?
        res = @https.post('/api/add', prm)
        if res.code != "201"
            error_insta_api(id, message, url, res.code)
        end
    end

    # Read it Later 登録予定リストにURL追加
    def add_url_ril(id, url, title)
        tmp = [id, url, title]
        @urls_ril << tmp
    end

    # Read it Later API呼び出し
    def call_ril_api()
        i = 0
        tmp_json = {}
        while 0 < @urls_ril.length
            url = @urls_ril.shift
            if url[2] != nil
                tmp = {"url" => "#{CGI.escape(url[1])}", "title" => "#{CGI.escape(url[2])}", "ref_id" => "#{url[0]}"}
            else
                tmp = {"url" => "#{CGI.escape(url[1])}", "ref_id" => "#{url[0]}"}
            end
            tmp_json["#{i}"] = tmp
            i += 1
        end
        if i > 0
            res = @https_ril.post('/v2/send', 'username=' + UserConfig[:urlsave_ril_user] +
                              '&password=' + UserConfig[:urlsave_ril_pass] + '&apikey=' +
                              URLSAVE_RIL_API_KEY + '&new=' + tmp_json.to_json)
            if res.code != "200"
                error_ril_api(res.code)
            end
        end
    end

    # Instapaper APIエラー
    def error_insta_api(id, message, url, res)
        if res == "400"
            notify("Exceeded the rate limit.\nid : #{id}\npost : #{message}\nurl : #{url}")
        elsif res == "403"
            notify("Invalid username or password.\nid : #{id}\npost : #{message}\nurl : #{url}")
        else
            notify("The service encountered an error. Please try again later.\nid : #{id}\npost : #{message}\nurl : #{url}")
        end
    end

    # Read it Later APIエラー
    def error_ril_api(res)
        if res == "400"
            notify("Invalid request.")
        elsif res == "401"
            notify("Username and/or password is incorrect.")
        elsif res == "403"
            notify("Rate limit exceeded.")
        elsif res == "503"
            notify("Read It Later's sync server is down for scheduled maintenance.")
        else
            notify("Unknown Error! respons code = #{res}")
        end
    end

    # 無視するURL?
    def ignore?(url)
        ignore_list = UserConfig[:urlsave_ignore]
        url = expand_url(url)
        if url == false
            return true
        end
        ignore_list.split("\n").each do |i|
            r = Regexp.new(i)
            if r =~ url
#                notify("Ignored!!\nurl : #{url}")
                return true
            end
        end
        return url
    end

    def notify(msg)
        Plugin.call(:update, nil, [Message.new(:message => msg, :system => true)])
    end

    def expand_url(s)
        loop do
            begin
                uri = URI(s)
            rescue Exception => exc
                print "in expand_url : URI(#{s}) "
                p exc
                return false
            end
            http = Net::HTTP.new(uri.host, uri.port)
            begin
                tmp = http.head(uri.request_uri)["Location"]
            rescue Exception => exc
                print "in expand_url : http.head(#{s}) "
                p exc
                return false
            end

            if tmp == nil
                return s
            end
            s = tmp
        end
    end

    def get_title(url)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if /^https/ =~ url
        begin
            title = http.get(uri.request_uri).body.toutf8.scan(/<title>(.*)<\/title>/)
        rescue Exception => exc
            print "in get_title : http.get(#{url})"
            p exc
            return nil
        end
        if title.length > 0
            return title[0][0]
        else
            return nil
        end
    end
end
