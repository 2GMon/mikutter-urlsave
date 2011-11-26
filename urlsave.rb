# -*- coding: utf-8 -*-
# requrie 'date'
require 'net/http'
require 'cgi'
require 'uri'
miquire :core, "serialthread"
miquire :addon, "settings"

Plugin::create(:urlsave) do
    settings("URLsave") do
        settings('基本設定') do
            input('ユーザー名', :urlsave_user)
            inputpass('パスワード', :urlsave_pass)
            boolean('URLsave起動', :urlsave_on)
        end
        settings("無視するURL") do
            multitext('無視するURL', :urlsave_ignore).
                tooltip('1行に一つrubyの正規表現で書く')
        end
    end

    @thread = SerialThreadGroup.new
    @https = Net::HTTP.new('www.instapaper.com', 443)
    @https.use_ssl = true
    onupdate do |service, message|
        @thread.new { instapaper(message) }
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
            if UserConfig[:urlsave_on]
                urls.each do |u|
                    if !ignore?(u)
                        call_insta_api(ent[:id], ent[:message], u) if UserConfig[:urlsave_user]
                    end
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
            error_api(id, message, url, res.code)
        end
    end

    # APIエラー
    def error_api(id, message, url, res)
        if res == "400"
            notify("Exceeded the rate limit.\nid : #{id}\npost : #{message}\nurl : #{url}")
        elsif res == "403"
            notify("Invalid username or password.\nid : #{id}\npost : #{message}\nurl : #{url}")
        else
            notify("The service encountered an error. Please try again later.\nid : #{id}\npost : #{message}\nurl : #{url}")
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
