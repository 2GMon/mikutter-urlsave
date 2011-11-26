# -*- coding: utf-8 -*-
# requrie 'date'
require 'net/http'
require 'cgi'
require 'uri'
require 'json'
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
                get_url_message_entity(m).each do |e|
                    add_url(e)
                end
            end
        end
    end

    # URLが含まれるentityをとってるつもり
    # 誰がかっこいいメソッド名考えて
    def get_url_message_entity(msg)
        entity = msg.links.to_a
        result = []
        if entity.length != 0
            entity.each do |e|
                if e[:slug] == :urls
                    result << e[:message]
                end
            end
        end
        result
    end

    # URLを追加する
    def add_url(ent)
        if !UserConfig[:urlsave_latest_id].to_i
            UserConfig[:urlsave_latest_id] = ent[:id].to_i
        end
        if ent[:id].to_i > UserConfig[:urlsave_latest_id].to_i
            UserConfig[:urlsave_latest_id] = ent[:id].to_i
            urls = []
            ent[:entities][:urls].each do |u|
                urls << u[:url]
            end
            urls.each do |u|
                if !ignore?(u)
                    call_insta_api(ent[:id], ent[:message], u) if !UserConfig[:urlsave_user].empty?
                    add_url_ril(ent[:id], u) if !UserConfig[:urlsave_ril_user].empty?
                end
            end
        end
    end

    # InstapaperAPI呼び出し
    def call_insta_api(id, message, url)
        if !UserConfig[:urlsave_pass].empty?
            res = @https.post('/api/add', 'username=' + UserConfig[:urlsave_user] +
                              '&password=' + UserConfig[:urlsave_pass] + '&url=' +
                              CGI.escape(url) + '&selection=' + CGI.escape(message))
        else
            res = @https.post('/api/add', 'username=' + UserConfig[:urlsave_user] +
                              '&url=' + CGI.escape(url) + '&selection=' + CGI.escape(message))
        end
        if res.code != "201"
            error_insta_api(id, message, url, res.code)
        end
    end

    # Read it Later 登録予定リストにURL追加
    def add_url_ril(id, url)
        tmp = [id, url]
        @urls_ril << tmp
    end

    # Read it Later API呼び出し
    def call_ril_api()
        i = 0
        tmp_json = {}
        while 0 < @urls_ril.length
            url = @urls_ril.shift
            tmp = {"url" => "#{url[1]}", "ref_id" => "#{url[0]}"}
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
        return false
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
end
