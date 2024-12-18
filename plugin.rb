# name: discourse-private-topics
# about: Allows to keep topics private to the topic creator and specific groups.
# version: 1.5.7
# authors: Communiteq
# meta_topic_id: 268646
# url: https://github.com/communiteq/discourse-private-topics

enabled_site_setting :private_topics_enabled

module ::DiscoursePrivateTopics
  # Кэш для уже скрытых тем
  @@hidden_topics_cache = Set.new

  # Функция для скрытия темы
  def self.hide_topic(topic)
    # Пропускаем закрепленные или уже скрытые темы
    return if topic.pinned || topic.hidden

    # Скрываем тему, используя встроенные методы Discourse
    topic.update_status("visible", false)

    # Логируем успешное скрытие
    Rails.logger.info("Тема #{topic.id} успешно скрыта.")
    
    # Добавляем тему в кэш
    @@hidden_topics_cache.add(topic.id)
  end

  # Функция для обработки всех тем в категории
  def self.process_topics
    Category.find_each do |category|
      category.topics.find_each do |topic|
        # Пропускаем тему с определенным ID
        #next if topic.id == EXCLUDED_TOPIC_ID 
        
        # Пропускаем, если тема уже скрыта
        next if @@hidden_topics_cache.include?(topic.id)

        # Вызываем функцию для скрытия темы
        hide_topic(topic)
      end
    end
  end

  # Получает список пользователей, которым всегда показываются темы
  def self.get_unfiltered_user_ids(user)
    user_ids = [ Discourse.system_user.id ]
    user_ids.append user.id if user && !user.anonymous?
    group_ids = SiteSetting.private_topics_permitted_groups.split("|").map(&:to_i)
    user_ids = user_ids + Group.where(id: group_ids).joins(:users).pluck('users.id')
    user_ids.uniq
  end

  # Получает список категорий, которые необходимо скрыть
  def self.get_filtered_category_ids(user)
    return [] unless SiteSetting.private_topics_enabled

    cat_ids = CategoryCustomField.where(name: 'private_topics_enabled').pluck(:category_id).to_a
    cat_group_map = cat_ids.map { |i| [i, []] }.to_h

    if user
      excluded_map = CategoryCustomField.
        where(category_id: cat_ids).
        where(name: 'private_topics_allowed_groups').
        each_with_object({}) do |record, h|
          h[record.category_id] = record.value.split(',').map(&:to_i)
        end
      cat_group_map.merge! (excluded_map)

      user_group_ids = user.groups.pluck(:id).to_a
      cat_group_map = cat_group_map.reject { |k, v| (v & user_group_ids).any? }
    end

    cat_group_map.keys
  end
end

after_initialize do
  # Вызываем функцию для обработки тем и скрытия
  ::DiscoursePrivateTopics.process_topics

  # Обработчик скрытия тем в поиске
  module PrivateTopicsPatchSearch
    def execute(readonly_mode: @readonly_mode)
      super

      if SiteSetting.private_topics_enabled && !(SiteSetting.private_topics_admin_sees_all & @guardian&.user&.admin?)
        cat_ids = DiscoursePrivateTopics.get_filtered_category_ids(@guardian.user)
        unless cat_ids.empty?
          user_ids = DiscoursePrivateTopics.get_unfiltered_user_ids(@guardian.user)
          @results.posts.delete_if do |post|
            next false if user_ids.include? post&.user&.id
            post&.topic&.category&.id && cat_ids.include?(post.topic.category&.id)
          end
        end
      end

      @results
    end
  end

  # Обработчик прав доступа к темам
  module ::TopicGuardian
    alias_method :org_can_see_topic?, :can_see_topic?

    def can_see_topic?(topic, hide_deleted = true)
      allowed = org_can_see_topic?(topic, hide_deleted)
      return false unless allowed 

      if SiteSetting.private_topics_enabled && !(SiteSetting.private_topics_admin_sees_all & @user&.admin?)
        return true unless topic&.category 

        user_ids = DiscoursePrivateTopics.get_unfiltered_user_ids(@user)
        return true if user_ids.include?(topic&.user&.id) 

        cat_ids = DiscoursePrivateTopics.get_filtered_category_ids(@user)
        return true if cat_ids.empty?

        return false if cat_ids.include?(topic.category&.id)
      end

      true
    end
  end
end
